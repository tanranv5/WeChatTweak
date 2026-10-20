"""Run the guard in disposable executables, never in the user's WeChat."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hotpatch", ROOT / "runtime/hotpatch.py")
hp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hp)

LOADER = r'''
#include <stdio.h>
static char roots[4096];
void set_config(const char *, const char *) __asm("__ZN4WCDY9setConfigEPKcS1_");
void set_config(const char *bundle, const char *download) {
    snprintf(roots, sizeof(roots), "%s|%s", bundle, download);
}
const char *get_roots(void) { return roots; }
'''

MAIN = r'''
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern void set_config(const char *, const char *) __asm("__ZN4WCDY9setConfigEPKcS1_");
extern const char *get_roots(void);
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "config")) {
        set_config("/bundled/Resources", "/downloaded/magicdy");
        puts(get_roots()); return 0;
    }
    if (argc < 3) return 2;
    if (!strcmp(argv[1], "dlopen")) {
        void *handle = dlopen(argv[2], RTLD_NOW);
        if (handle) { dlclose(handle); puts("allowed"); }
        else puts(dlerror() ? "denied-with-error" : "denied-without-error");
        return 0;
    }
    if (!strcmp(argv[1], "fopen")) {
        FILE *f = fopen(argv[2], "r");
        if (f) { fclose(f); puts("allowed"); }
        else printf("denied:%d\n", errno);
        return 0;
    }
    int descriptor;
    if (!strcmp(argv[1], "openat")) {
        if (argc < 4) return 2;
        int parent = open(argv[2], O_RDONLY);
        descriptor = openat(parent, argv[3], O_RDONLY);
        int saved = errno;
        close(parent); errno = saved;
    } else if (!strcmp(argv[1], "create")) {
        descriptor = open(argv[2], O_CREAT | O_WRONLY | O_EXCL, 0600);
    } else if (!strcmp(argv[1], "relative")) {
        if (argc < 4 || chdir(argv[2])) return 2;
        descriptor = open(argv[3], O_RDONLY);
    } else {
        descriptor = open(argv[2], O_RDONLY);
    }
    if (descriptor >= 0) { close(descriptor); puts("allowed"); }
    else printf("denied:%d\n", errno);
    return 0;
}
'''


def run(*args):
    result = subprocess.run([str(x) for x in args], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, args,
                                            output=result.stdout, stderr=result.stderr)
    return result.stdout.strip()


class HotPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="wxhotpatch-tests-")
        cls.root = Path(cls.temp.name)
        # Disposable apps must not compete with the real app in LaunchServices.
        cls.production_identifier = hp.APP_IDENTIFIER
        hp.APP_IDENTIFIER = "app.wechattweak.hotpatch-fixture"
        cls.source = cls.root / "source app.app"
        cls.library = ROOT / "runtime/build" / hp.LIBRARY
        cls.loader = cls.source / hp.FRAMEWORK
        cls.main = cls.source / hp.MAIN
        cls.loader.parent.mkdir(parents=True)
        resources = cls.loader.parent / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "test.WCDY",
            "CFBundleExecutable": "WCDY",
            "CFBundlePackageType": "FMWK",
            "CFBundleVersion": "1",
        }))
        framework = cls.loader.parents[2]
        (framework / "Versions/Current").symlink_to("A")
        (framework / "WCDY").symlink_to("Versions/Current/WCDY")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        cls.main.parent.mkdir(parents=True)
        (cls.source / "Contents/Resources").mkdir()
        (cls.source / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": hp.APP_IDENTIFIER,
            "CFBundleVersion": "268602",
            "CFBundleExecutable": "WeChat",
            "CFBundlePackageType": "APPL",
        }))
        (cls.root / "loader.c").write_text(LOADER)
        (cls.root / "main.c").write_text(MAIN)
        common = ["clang", "-arch", "arm64", "-arch", "x86_64",
                  "-mmacosx-version-min=12.0", "-Wl,-no_fixup_chains"]
        run(*common, "-dynamiclib", cls.root / "loader.c", "-o", cls.loader,
            "-install_name",
            "@executable_path/../Frameworks/WCDY.framework/Versions/A/WCDY")
        run(*common, cls.root / "main.c", cls.loader, "-o", cls.main,
            "-Wl,-headerpad,0x400")
        run("codesign", "--force", "--deep", "--sign", "-", cls.source)
        # Only the test process substitutes the fake loader's identity.
        cls.production_catalog = hp.SUPPORTED
        hp.SUPPORTED = {"268602": {i.arch: i.identity()
                                  for i in hp.images(cls.loader.read_bytes())}}
        cls.before = hashlib.sha256(cls.main.read_bytes()).hexdigest()
        cls.prepared = cls.root / "prepared app.app"
        hp.prepare(cls.source, cls.prepared, cls.library)
        cls.executable = cls.prepared / hp.MAIN
        cls.data = cls.root / "Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data"
        for channel in ("magic", "magicdy", "xplugin/plugins/Magic",
                        "xplugin/plugins/Magicdy", "xplugin/plugins/Other", "magical"):
            path = cls.data / channel
            path.mkdir(parents=True)
            (path / "payload").write_text("test")
        cls.architectures = ["arm64"]
        try:
            run("/usr/bin/arch", "-x86_64", cls.main, "config")
            cls.architectures.append("x86_64")
        except subprocess.CalledProcessError:
            print("x86_64 runtime tests unavailable: Rosetta is not available")
        print("Runtime test architectures:", ", ".join(cls.architectures))

    @classmethod
    def tearDownClass(cls):
        hp.SUPPORTED = cls.production_catalog
        hp.APP_IDENTIFIER = cls.production_identifier
        cls.temp.cleanup()

    def invoke(self, *args, source=False):
        executable = self.main if source else self.executable
        results = [run("/usr/bin/arch", f"-{arch}", executable, *args)
                   for arch in self.architectures]
        self.assertTrue(all(x == results[0] for x in results))
        return results[0]

    def test_wcdY_preserves_bundle_and_redirects_downloads(self):
        self.assertEqual(self.invoke("config", source=True),
                         "/bundled/Resources|/downloaded/magicdy")
        self.assertEqual(self.invoke("config"), "/bundled/Resources|/dev/null")

    def test_magic_and_magicdy_reads_are_denied(self):
        for channel in ("magic", "magicdy", "xplugin/plugins/Magic",
                        "xplugin/plugins/Magicdy"):
            for method in ("open", "fopen"):
                with self.subTest(channel=channel, method=method):
                    path = self.data / channel / "payload"
                    self.assertEqual(self.invoke(method, path, source=True), "allowed")
                    self.assertEqual(self.invoke(method, path), "denied:13")

    def test_relative_openat_and_alias(self):
        self.assertEqual(self.invoke("openat", self.data, "magic/payload"), "denied:13")
        self.assertEqual(self.invoke("relative", self.data, "./magic/payload"), "denied:13")
        alias = self.root / "payload-alias"
        alias.symlink_to(self.data / "magic/payload")
        self.assertEqual(self.invoke("open", alias), "denied:13")
        self.assertEqual(self.invoke("open", str(self.data) + "/magic/../magical/payload"),
                         "allowed")

    def test_other_plugins_and_creation_are_preserved(self):
        for path in (self.data / "xplugin/plugins/Other/payload",
                     self.data / "magical/payload"):
            self.assertEqual(self.invoke("open", path), "allowed")
        for arch in self.architectures:
            path = self.root / ("created-" + arch)
            self.assertEqual(run("/usr/bin/arch", f"-{arch}", self.executable, "create", path),
                             "allowed")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_dlopen_is_guarded_and_reports_error(self):
        payload = self.data / "magic/payload.dylib"
        allowed = self.data / "magical/payload.dylib"
        shutil.copy2(self.loader, payload)
        shutil.copy2(self.loader, allowed)
        self.assertEqual(self.invoke("dlopen", payload, source=True), "allowed")
        self.assertEqual(self.invoke("dlopen", payload), "denied-with-error")
        self.assertEqual(self.invoke("dlopen", allowed), "allowed")
        self.assertEqual(self.invoke("dlopen", self.loader), "allowed")

    def test_source_unchanged_and_prepared_copy_verified(self):
        self.assertEqual(hashlib.sha256(self.main.read_bytes()).hexdigest(), self.before)
        self.assertFalse((self.source / "Contents/Resources" / hp.LIBRARY).exists())
        state = hp.qualify(self.prepared)
        self.assertTrue(state["guard_dependency"])
        self.assertFalse(state["running_process_verified"])
        run("codesign", "--verify", "--deep", "--strict", self.prepared)

    def test_weak_dependency_allows_rollback_by_removing_guard(self):
        copy = self.root / "without guard.app"
        shutil.copytree(self.prepared, copy, symlinks=True)
        (copy / "Contents/Resources" / hp.LIBRARY).unlink()
        run("codesign", "--force", "--deep", "--sign", "-", copy)
        self.assertEqual(run(copy / hp.MAIN, "config"),
                         "/bundled/Resources|/downloaded/magicdy")

    def test_dependency_is_idempotent_and_other_ordinals_unchanged(self):
        original = self.main.read_bytes()
        patched = hp.inject(original)
        self.assertEqual(hp.inject(patched), patched)
        for before, after in zip(hp.images(original), hp.images(patched)):
            self.assertEqual(after.dependencies, before.dependencies + [hp.LOAD_NAME])
            self.assertEqual(before.text, after.text)

    def test_version_and_loader_drift_refused(self):
        copy = self.root / "drift.app"
        shutil.copytree(self.source, copy, symlinks=True)
        plist = copy / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleVersion"] = "270100"
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(hp.GuardError, "not qualified"):
            hp.qualify(copy)
        info["CFBundleVersion"] = "268602"
        plist.write_bytes(plistlib.dumps(info))
        code = bytearray((copy / hp.FRAMEWORK).read_bytes())
        image = hp.images(code)[0]
        position = code.find(image.text, image.offset)
        code[position] ^= 1
        (copy / hp.FRAMEWORK).write_bytes(code)
        with self.assertRaisesRegex(hp.GuardError, "Unrecognized WCDY"):
            hp.qualify(copy)

    def test_existing_output_and_source_descendant_refused(self):
        for output in (self.prepared, self.source / "nested.app"):
            with self.assertRaisesRegex(hp.GuardError, "new path"):
                hp.prepare(self.source, output, self.library)

    def test_signing_failure_does_not_publish_or_change_source(self):
        output = self.root / "failed-signing.app"
        execute = hp.run

        def fail_signing(arguments):
            if arguments[0] == "/usr/bin/codesign":
                raise subprocess.CalledProcessError(1, arguments)
            execute(arguments)

        with patch.object(hp, "run", side_effect=fail_signing):
            with self.assertRaises(subprocess.CalledProcessError):
                hp.prepare(self.source, output, self.library)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.root.glob(".wxhotpatch-*")))
        self.assertEqual(hashlib.sha256(self.main.read_bytes()).hexdigest(), self.before)

    def test_header_space_refusal(self):
        data = bytearray(self.main.read_bytes())
        image = hp.images(data)[0]
        data[image.offset + 32 + image.command_size] = 0xFF
        with self.assertRaisesRegex(hp.GuardError, "header space"):
            hp.inject(data)

    def test_external_symlink_refused(self):
        copy = self.root / "symlink.app"
        shutil.copytree(self.source, copy, symlinks=True)
        (copy / "Contents/Resources/outside").symlink_to(self.root / "main.c")
        with self.assertRaisesRegex(hp.GuardError, "External bundle symlink"):
            hp.prepare(copy, self.root / "symlink-output.app", self.library)
        self.assertFalse((self.root / "symlink-output.app").exists())

    def test_truncated_and_overlapping_macho_refused(self):
        for data in (b"", bytes(32), self.main.read_bytes()[:20]):
            with self.assertRaises((hp.GuardError, struct.error)):
                hp.images(data)
        data = bytearray(self.main.read_bytes())
        struct.pack_into(">I", data, 8 + 20 + 8, struct.unpack_from(">I", data, 16)[0])
        with self.assertRaisesRegex(hp.GuardError, "Overlapping"):
            hp.images(data)


if __name__ == "__main__":
    unittest.main()
