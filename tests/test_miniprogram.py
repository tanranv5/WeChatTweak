import hashlib
from pathlib import Path
import struct
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
import hotpatch
import miniprogram as repair


def thin(arch, identity, entries):
    size = 0x1040
    data = bytearray(size)
    cpu = 0x100000C if arch == "arm64" else 0x1000007
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, cpu, 0, 6, 2, 176, 0, 0)
    struct.pack_into("<II16s4Q4I", data, 32, 0x19, 152, b"__TEXT",
                     0, 0x2000, 0, size, 7, 5, 1, 0)
    struct.pack_into("<16s16sQQ8I", data, 104, b"__text", b"__TEXT",
                     0x1000, 64, 0x1000, 4, 0, 0, 0x80000400, 0, 0, 0)
    struct.pack_into("<II16s", data, 184, 0x1B, 24, uuid.UUID(identity).bytes)
    for address, before, _ in entries:
        data[address:address + len(bytes.fromhex(before))] = bytes.fromhex(before)
    return bytes(data)


class MiniProgramRepairTests(unittest.TestCase):
    def setUp(self):
        self.identities, self.patches = repair.IDENTITIES, repair.PATCHES
        repair.PATCHES = {
            "arm64": [(0x1000, "c17f8352", "c17f8052"),
                      (0x1010, "21008052", "21028052")],
            "x86_64": [(0x1000, "befe1b0000", "befe030000"),
                       (0x1010, "be01000000", "be11000000")],
        }
        repair.IDENTITIES = {}
        self.slices = []
        for arch in ("x86_64", "arm64"):
            data = thin(arch, str(uuid.uuid4()), repair.PATCHES[arch])
            image = hotpatch.images(data)[0]
            repair.IDENTITIES[arch] = image.identity()
            self.slices.append(data)
        self.data = bytearray(0xC000)
        struct.pack_into(">II", self.data, 0, 0xCAFEBABE, 2)
        for index, (cpu, data) in enumerate(zip((0x1000007, 0x100000C), self.slices)):
            offset = 0x4000 * (index + 1)
            struct.pack_into(">5I", self.data, 8 + 20 * index,
                             cpu, 0, offset, len(data), 14)
            self.data[offset:offset + len(data)] = data

    def tearDown(self):
        repair.IDENTITIES, repair.PATCHES = self.identities, self.patches

    def test_only_expected_instructions_change_and_apply_is_idempotent(self):
        before = bytes(self.data)
        after = repair.patched(before)
        self.assertEqual(repair.inspect(after), {"x86_64": "applied", "arm64": "applied"})
        self.assertEqual(repair.patched(after), after)
        allowed = set()
        for image in hotpatch.images(before):
            for address, original, replacement in repair.PATCHES[image.arch]:
                offset = image.file_offset(address, len(bytes.fromhex(original)))
                allowed.update(range(offset, offset + len(bytes.fromhex(original))))
        actual = {index for index, pair in enumerate(zip(before, after)) if pair[0] != pair[1]}
        self.assertTrue(actual)
        self.assertTrue(actual <= allowed)
        self.assertEqual(bytes(self.data), before)

    def test_unknown_instruction_fails_before_any_mutation(self):
        self.data[0x8000 + 0x1010] ^= 1
        before = bytes(self.data)
        with self.assertRaisesRegex(hotpatch.GuardError, "Unexpected code"):
            repair.patched(self.data)
        self.assertEqual(bytes(self.data), before)

    def test_unrelated_code_drift_rejected_even_with_same_uuid(self):
        self.data[0x8000 + 0x1020] = 1
        with self.assertRaisesRegex(hotpatch.GuardError, "executable code"):
            repair.patched(self.data)

    def test_unknown_uuid_rejected(self):
        self.data[0x4000 + 192] ^= 1
        with self.assertRaisesRegex(hotpatch.GuardError, "Unknown WMPF UUID"):
            repair.patched(self.data)

    def test_partial_known_patch_can_be_completed(self):
        image = hotpatch.images(self.data)[0]
        address, before, replacement = repair.PATCHES[image.arch][0]
        offset = image.file_offset(address, len(bytes.fromhex(before)))
        self.data[offset:offset + len(bytes.fromhex(before))] = bytes.fromhex(replacement)
        self.assertEqual(repair.inspect(self.data)["x86_64"], "partial")
        self.assertTrue(all(x == "applied" for x in repair.inspect(repair.patched(self.data)).values()))

    def test_missing_architecture_rejected(self):
        with self.assertRaisesRegex(hotpatch.GuardError, "architectures"):
            repair.patched(self.slices[0])

    def test_out_of_segment_address_rejected(self):
        repair.PATCHES["arm64"] = [(0xFFFF, "0000", "1111")]
        with self.assertRaisesRegex(hotpatch.GuardError, "file-backed"):
            repair.patched(self.data)


if __name__ == "__main__":
    unittest.main()
