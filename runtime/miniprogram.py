#!/usr/bin/env python3
"""Repair the qualified WMPF crash-metadata startup stall in an app copy."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import hotpatch

FRAMEWORK = Path(
    "Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/"
    "WeChatAppEx Framework.framework/Versions/C/WeChatAppEx Framework")

# Only the executable sections of the locally inspected 268602 framework.
# Signatures and unrelated binary metadata may change without changing code.
IDENTITIES = {
    "arm64": {
        "uuid": "4c4c44ff-5555-3144-a172-38161327c7de",
        "text_sha256": "fda29b37433d5f92f6c542cea0e2df63c5521a300ab8fe48b91b0d4432fc988a",
    },
    "x86_64": {
        "uuid": "4c4c44d1-5555-3144-a1d6-858bb7c5f490",
        "text_sha256": "12bec620924a2d9dee4fb02402052717d8c88073cd1abee08d515ba4d28f3a5b",
    },
}

# task_get_exception_ports mask: 0x1bfe -> 0x03fe in SendDataToHandle only.
# This excludes resource/guard-only OS endpoints from proprietary metadata.
# mach_msg options: MACH_SEND_MSG -> MACH_SEND_MSG | MACH_SEND_TIMEOUT.
# The existing timeout argument is zero: the send queues immediately or fails.
# No installed exception handler or ordinary IPC call is changed.
PATCHES = {
    "arm64": [
        (0x586AE6C, "c17f8352", "c17f8052"),
        (0x58714D4, "21008052", "21028052"),
    ],
    "x86_64": [
        (0x639B55D, "befe1b0000", "befe030000"),
        (0x63A2342, "be01000000", "be11000000"),
    ],
}


def inspect(data):
    normalized = bytearray(data)
    states = {}
    slices = hotpatch.images(data)
    if {image.arch for image in slices} != set(IDENTITIES):
        raise hotpatch.GuardError("Unexpected WMPF architectures")
    for image in slices:
        if image.uuid != IDENTITIES[image.arch]["uuid"]:
            raise hotpatch.GuardError(f"Unknown WMPF UUID: {image.arch}")
        applied = []
        for address, before_hex, after_hex in PATCHES[image.arch]:
            before, after = bytes.fromhex(before_hex), bytes.fromhex(after_hex)
            if len(before) != len(after):
                raise hotpatch.GuardError("Patch length mismatch")
            offset = image.file_offset(address, len(before))
            current = bytes(data[offset:offset + len(before)])
            if current not in (before, after):
                raise hotpatch.GuardError(f"Unexpected code at {image.arch}:{address:#x}")
            applied.append(current == after)
            normalized[offset:offset + len(before)] = before
        states[image.arch] = ("applied" if all(applied) else
                              "original" if not any(applied) else "partial")
    for image in hotpatch.images(normalized):
        if image.identity() != IDENTITIES[image.arch]:
            raise hotpatch.GuardError(f"Unrecognized WMPF executable code: {image.arch}")
    return states


def patched(data):
    inspect(data)  # Check every slice before changing any byte.
    result = bytearray(data)
    for image in hotpatch.images(data):
        for address, _, after in PATCHES[image.arch]:
            replacement = bytes.fromhex(after)
            offset = image.file_offset(address, len(replacement))
            result[offset:offset + len(replacement)] = replacement
    return bytes(result)


def qualify(app):
    state = hotpatch.qualify(app)
    app = app.resolve(strict=True)
    target = app / FRAMEWORK
    if not target.resolve(strict=True).is_relative_to(app):
        raise hotpatch.GuardError("WMPF framework escapes the application")
    state["mini_program_fix"] = inspect(target.read_bytes())
    return state


def prepare(app, output):
    app = app.resolve(strict=True)
    before = qualify(app)
    original = (app / FRAMEWORK).read_bytes()
    fixed = patched(original)
    guard = app / "Contents/Resources" / hotpatch.LIBRARY
    guard_hash = hashlib.sha256(guard.read_bytes()).digest() if guard.is_file() else None

    def edit(staged):
        target = staged / FRAMEWORK
        target.write_bytes(fixed)
        hotpatch.run(["/usr/bin/codesign", "--force", "--sign", "-",
                      "--preserve-metadata=entitlements", str(target)])

    def verify(staged):
        after = qualify(staged)
        if not all(value == "applied" for value in after["mini_program_fix"].values()):
            raise hotpatch.GuardError("Mini Programs repair did not verify")
        for key in ("guard_dependency", "guard_library_present"):
            if before[key] != after[key]:
                raise hotpatch.GuardError("Hot-patch guard state changed")
        if guard_hash is not None:
            installed = staged / "Contents/Resources" / hotpatch.LIBRARY
            if hashlib.sha256(installed.read_bytes()).digest() != guard_hash:
                raise hotpatch.GuardError("Hot-patch guard binary changed")
        return after

    return hotpatch.prepare_copy(app, output, edit, verify)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "prepare"])
    parser.add_argument("--app", type=Path, default=Path("/Applications/WeChat.app"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare":
            if args.output is None:
                parser.error("prepare requires --output")
            result = prepare(args.app, args.output)
        else:
            result = qualify(args.app)
        print(json.dumps(result, indent=2))
        return 0
    except (hotpatch.GuardError, OSError, ValueError,
            subprocess.CalledProcessError) as error:
        print(f"Mini Programs repair: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
