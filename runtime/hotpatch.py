#!/usr/bin/env python3
"""Inspect or prepare a separate WeChat.app with the native patch guard."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

LIBRARY = "libwxhotpatchguard.dylib"
APP_IDENTIFIER = "com.tencent.xinWeChat"
LOAD_NAME = f"@executable_path/../Resources/{LIBRARY}"
SET_CONFIG = "__ZN4WCDY9setConfigEPKcS1_"
FRAMEWORK = Path("Contents/Frameworks/WCDY.framework/Versions/A/WCDY")
MAIN = Path("Contents/MacOS/WeChat")
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
ARCHES = {0x1000007: "x86_64", 0x100000C: "arm64"}

# Qualified from WeChat 4.1.9.58 / 268602. These hashes cover __TEXT,__text,
# not code-signature metadata. Other loaders need a separate qualification.
SUPPORTED = {
    "268602": {
        "arm64": {
            "uuid": "9ca993ed-03bf-38aa-8e8d-2499abbe759e",
            "text_sha256": "63d73daeb00d3b980123041130cbcdc46df8cf72e0bc8c58fe2afdef3816061d",
        },
        "x86_64": {
            "uuid": "ff016acb-e894-3ad0-ac76-55574dd13ddf",
            "text_sha256": "80f4bfb6b024391617ae23dd4030a5e3f320b6c8969c892efb3708e8e43ceac1",
        },
    }
}


class GuardError(Exception):
    pass


class Image:
    """Bounded reader for little-endian 64-bit Mach-O in thin/FAT files."""

    def __init__(self, data, offset, size):
        self.data, self.offset, self.size = data, offset, size
        if offset < 0 or size < 32 or offset + size > len(data):
            raise GuardError("Invalid Mach-O slice bounds")
        header = self.unpack("<8I", 0)
        if header[0] != 0xFEEDFACF or header[1] not in ARCHES:
            raise GuardError("Only arm64 and x86_64 Mach-O slices are supported")
        self.arch = ARCHES[header[1]]
        self.count, self.command_size = header[4:6]
        if self.command_size > size - 32 or self.count > self.command_size // 8:
            raise GuardError("Invalid load-command bounds")
        self.commands, self.dependencies, self.symbols = [], [], set()
        self.uuid, self.text = None, None
        self.first_section = size
        cursor = 32
        end = cursor + self.command_size
        for _ in range(self.count):
            command, length = self.unpack("<II", cursor)
            if length < 8 or length % 8 or cursor + length > end:
                raise GuardError("Invalid load command")
            self.commands.append((command, cursor, length))
            if command in DYLIB_COMMANDS:
                if length < 24:
                    raise GuardError("Invalid dylib command")
                name_offset = self.unpack("<I", cursor + 8)[0]
                if not 24 <= name_offset < length:
                    raise GuardError("Invalid dylib name offset")
                self.dependencies.append(self.cstring(cursor + name_offset,
                                                      cursor + length))
            elif command == 0x1B:
                if length != 24:
                    raise GuardError("Invalid UUID command")
                self.uuid = str(uuid.UUID(bytes=self.bytes(cursor + 8, 16)))
            elif command == 0x19:
                if length < 72:
                    raise GuardError("Invalid segment command")
                sections = self.unpack("<I", cursor + 64)[0]
                if 72 + sections * 80 != length:
                    raise GuardError("Invalid section table")
                for i in range(sections):
                    section = cursor + 72 + i * 80
                    name = self.bytes(section, 16).split(b"\0", 1)[0]
                    segment = self.bytes(section + 16, 16).split(b"\0", 1)[0]
                    byte_count = self.unpack("<Q", section + 40)[0]
                    file_offset = self.unpack("<I", section + 48)[0]
                    flags = self.unpack("<I", section + 64)[0] & 0xFF
                    if byte_count and flags not in (1, 0xC, 0x12):
                        self.bytes(file_offset, byte_count)
                        self.first_section = min(self.first_section, file_offset)
                        if name == b"__text" and segment == b"__TEXT":
                            self.text = self.bytes(file_offset, byte_count)
            elif command == 2:
                if length != 24:
                    raise GuardError("Invalid symbol command")
                symoff, count, stroff, strsize = self.unpack("<4I", cursor + 8)
                self.bytes(symoff, count * 16)
                self.bytes(stroff, strsize)
                for i in range(count):
                    name, = self.unpack("<I", symoff + i * 16)
                    if name >= strsize:
                        raise GuardError("Invalid symbol name")
                    if name:
                        self.symbols.add(self.cstring(stroff + name, stroff + strsize))
            cursor += length
        if cursor != end:
            raise GuardError("Load-command size mismatch")

    def bytes(self, position, length):
        if position < 0 or length < 0 or position + length > self.size:
            raise GuardError("Mach-O range exceeds slice")
        return bytes(self.data[self.offset + position:self.offset + position + length])

    def unpack(self, fmt, position):
        return struct.unpack(fmt, self.bytes(position, struct.calcsize(fmt)))

    def cstring(self, start, end):
        value = self.bytes(start, end - start)
        if b"\0" not in value:
            raise GuardError("Unterminated Mach-O string")
        return value.split(b"\0", 1)[0].decode("utf-8", errors="strict")

    def identity(self):
        return {"uuid": self.uuid,
                "text_sha256": hashlib.sha256(self.text or b"").hexdigest()}

    def file_offset(self, address, length):
        for command, cursor, _ in self.commands:
            if command == 0x19:
                vm, _, fileoff, filesize = self.unpack("<4Q", cursor + 24)
                if address >= vm and address - vm + length <= filesize:
                    self.bytes(fileoff + address - vm, length)
                    return self.offset + fileoff + address - vm
        raise GuardError("Patch address is outside file-backed segments")


def images(data):
    if len(data) < 8:
        raise GuardError("Truncated Mach-O")
    magic, count = struct.unpack_from(">II", data)
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return [Image(data, 0, len(data))]
    entry_size = 32 if magic == 0xCAFEBABF else 20
    if not 1 <= count <= 16 or 8 + count * entry_size > len(data):
        raise GuardError("Invalid FAT header")
    result, regions = [], []
    for i in range(count):
        entry = 8 + i * entry_size
        if entry_size == 32:
            cpu, _, offset, size, _, _ = struct.unpack_from(">IIQQII", data, entry)
        else:
            cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, entry)
        if offset < 8 + count * entry_size or any(
                offset < b and a < offset + size for a, b in regions):
            raise GuardError("Overlapping FAT slices")
        image = Image(data, offset, size)
        if image.arch != ARCHES.get(cpu) or any(x.arch == image.arch for x in result):
            raise GuardError("Invalid or duplicate FAT architecture")
        result.append(image)
        regions.append((offset, offset + size))
    return result


def inject(data, load_name=LOAD_NAME):
    """Append the dependency without changing existing dylib ordinals."""
    result = bytearray(data)
    name = load_name.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    command = (struct.pack("<6I", 0x80000018, size, 24, 0, 0x10000, 0) +
               name).ljust(size, b"\0")
    for image in images(data):
        if load_name in image.dependencies:
            continue
        start = 32 + image.command_size
        if start + size > image.first_section or image.bytes(start, size) != bytes(size):
            raise GuardError(f"No safe header space in {image.arch}")
        absolute = image.offset + start
        result[absolute:absolute + size] = command
        struct.pack_into("<II", result, image.offset + 16,
                         image.count + 1, image.command_size + size)
    return bytes(result)


def qualify(app):
    app = app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != APP_IDENTIFIER:
        raise GuardError("The source is not com.tencent.xinWeChat")
    version = str(info.get("CFBundleVersion", ""))
    if version not in SUPPORTED:
        raise GuardError(f"Hot-patch guard is not qualified for build {version}")
    for relative in (FRAMEWORK, MAIN):
        if not (app / relative).resolve(strict=True).is_relative_to(app):
            raise GuardError("Binary symlink escapes the application")
    loader = images((app / FRAMEWORK).read_bytes())
    executable = images((app / MAIN).read_bytes())
    for image in loader:
        if image.identity() != SUPPORTED[version].get(image.arch):
            raise GuardError(f"Unrecognized WCDY code in {image.arch}")
        if SET_CONFIG not in image.symbols:
            raise GuardError(f"WCDY setConfig ABI is missing in {image.arch}")
    if {x.arch for x in executable} != {x.arch for x in loader}:
        raise GuardError("Main executable and WCDY architectures differ")
    if any(SET_CONFIG not in x.symbols for x in executable):
        raise GuardError("Main executable does not reference WCDY setConfig")
    return {"build": version, "architectures": [x.arch for x in executable],
            "qualified_layout": True,
            "guard_dependency": all(LOAD_NAME in x.dependencies for x in executable),
            "guard_library_present": (app / "Contents/Resources" / LIBRARY).is_file(),
            "running_process_verified": False}


def run(arguments):
    subprocess.run(arguments, check=True)


def prepare(app, output, library):
    app = app.resolve(strict=True)
    state = qualify(app)
    guard_images = images(library.read_bytes())
    if set(state["architectures"]) - {x.arch for x in guard_images}:
        raise GuardError("Guard library does not cover every app architecture")
    patched = inject((app / MAIN).read_bytes())

    def edit(staged):
        (staged / MAIN).write_bytes(patched)
        destination = staged / "Contents/Resources" / LIBRARY
        if destination.is_symlink():
            raise GuardError("Guard destination must not be a symlink")
        shutil.copy2(library, destination)
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination)])

    def verify(staged):
        verified = qualify(staged)
        if not verified["guard_dependency"] or not verified["guard_library_present"]:
            raise GuardError("Guard installation did not verify")
        return verified

    return prepare_copy(app, output, edit, verify)


def prepare_copy(app, output, edit, verify):
    """Edit and verify a disposable app, then publish it without replacing files."""
    app = app.resolve(strict=True)
    output = output.absolute()
    # Resolve the existing parent; do not follow a dangling destination link.
    parent = output.parent.resolve(strict=True)
    output = parent / output.name
    if os.path.lexists(output) or parent.is_relative_to(app):
        raise GuardError("Output must be a new path outside the source app")
    if output.suffix != ".app":
        raise GuardError("Output must end in .app")
    # A copied app must not sign or overwrite objects outside its own bundle.
    for root, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = Path(root) / name
            if path.is_symlink() and not path.resolve().is_relative_to(app):
                raise GuardError(f"External bundle symlink: {path.relative_to(app)}")
    with tempfile.TemporaryDirectory(prefix=".wxhotpatch-", dir=parent) as temporary:
        staged = Path(temporary) / output.name
        run(["/usr/bin/ditto", str(app), str(staged)])
        edit(staged)
        run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-",
             "--preserve-metadata=entitlements", str(staged)])
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)])
        verified = verify(staged)
        # renamex_np(RENAME_EXCL) prevents overwriting a destination created
        # while the app was being prepared.
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(staged), os.fsencode(output), 0x00000004) != 0:
            raise OSError(ctypes.get_errno(), "Cannot publish prepared application")
    return dict(verified, output=str(output), source_unchanged=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "prepare"])
    parser.add_argument("--app", type=Path, default=Path("/Applications/WeChat.app"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--library", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare":
            if args.output is None or args.library is None:
                parser.error("prepare requires --output and --library")
            state = prepare(args.app, args.output, args.library)
        else:
            state = qualify(args.app)
        print(json.dumps(state, indent=2))
        return 0
    except (GuardError, OSError, ValueError, struct.error,
            subprocess.CalledProcessError) as error:
        print(f"Hot-patch guard: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
