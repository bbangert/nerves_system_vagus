#!/usr/bin/env python3
"""Run from the repo root: python3 -I tools/test_mk_ufs_image.py

The source image and GPT parsing here are written independently of the tool
so a bug in the tool's own parser cannot make its output look valid.
"""

import binascii
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mk_ufs_image.py")

SS = 4096
MIB = 1 << 20
GIB = 1 << 30
DISK = 16 * GIB

# (name, start, count) in fwup's 512-byte units.
LAYOUT = [
    ("env", 2048, 2048),
    ("bootfs", 32768, 524288),
    ("rootfs-a", 557056, 1048576),
    ("rootfs-b", 1605632, 1048576),
    ("data", 2654208, 1048576),
]
LINUX_TYPE = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le
ESP_TYPE = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
# bootfs as fwup.conf marks it; rootfs-b sets every byte so a carry of only
# the low bits would show.
ATTRS = {"bootfs": 0x4, "rootfs-b": 0x8877665544332211}


def crc(b):
    return binascii.crc32(b) & 0xFFFFFFFF


def guid(n):
    return uuid.UUID(int=0x1234567890ABCDEF0000000000000000 | n).bytes_le


def hdr(cur, alt, first, last, disk_guid, ent_lba, ent_crc):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    struct.pack_into("<IIII", h, 8, 0x10000, 92, 0, 0)
    struct.pack_into("<QQQQ", h, 24, cur, alt, first, last)
    h[56:72] = disk_guid
    struct.pack_into("<QIII", h, 72, ent_lba, 128, 128, ent_crc)
    struct.pack_into("<I", h, 16, crc(bytes(h)))
    return bytes(h)


def make_source(path, layout=LAYOUT, order=None):
    """Minimal 512-LBA fwup-shaped image: primary GPT, markers at each
    partition start, and a backup GPT right after the data minimum with MiB
    padding after it, as `fwup -a -t complete` produces."""
    entries = bytearray(128 * 128)
    types = [ESP_TYPE, LINUX_TYPE, LINUX_TYPE, LINUX_TYPE, LINUX_TYPE]
    for slot, (name, start, count) in enumerate(layout):
        e = entries[slot * 128 : (slot + 1) * 128]
        e[0:16] = types[slot % 5]
        e[16:32] = guid(slot + 1)
        struct.pack_into("<QQQ", e, 32, start, start + count - 1, ATTRS.get(name, 0))
        e[56:56 + 2 * len(name)] = name.encode("utf-16le")
        entries[slot * 128 : (slot + 1) * 128] = e
    entries = bytes(entries)
    end = max(s + c for _, s, c in layout)
    backup_lba = end + 33
    disk_guid = guid(0xD0)
    ecrc = crc(entries)

    mbr = bytearray(512)
    mbr[446:462] = struct.pack("<B3sB3sII", 0, b"\0\2\0", 0xEE, b"\xff\xff\xff", 1, backup_lba)
    mbr[510:512] = b"\x55\xaa"
    total = -(-(backup_lba + 1) * 512 // MIB) * MIB
    with open(path, "wb") as f:
        f.truncate(total)
        f.write(mbr)
        f.write(hdr(1, backup_lba, 34, end, disk_guid, 2, ecrc))
        f.seek(2 * 512)
        f.write(entries)
        for name, start, _ in layout:
            f.seek(start * 512)
            f.write(b"MARK-" + name.encode())
        f.seek((backup_lba - 32) * 512)
        f.write(entries)
        f.seek(backup_lba * 512)
        f.write(hdr(backup_lba, 1, 34, end, disk_guid, backup_lba - 32, ecrc))
    return disk_guid, total


def read_gpt(buf_header, buf_entries):
    assert buf_header[:8] == b"EFI PART"
    stored = struct.unpack_from("<I", buf_header, 16)[0]
    z = bytearray(buf_header[:92])
    struct.pack_into("<I", z, 16, 0)
    assert crc(bytes(z)) == stored, "header CRC"
    cur, alt, first, last = struct.unpack_from("<QQQQ", buf_header, 24)
    ent_lba, n, size, ecrc = struct.unpack_from("<QIII", buf_header, 72)
    assert (n, size) == (128, 128)
    assert crc(buf_entries) == ecrc, "entries CRC"
    parts = {}
    for i in range(n):
        e = buf_entries[i * 128 : (i + 1) * 128]
        if e[0:16] == bytes(16):
            continue
        f, l = struct.unpack_from("<QQ", e, 32)
        name = e[56:].decode("utf-16le").rstrip("\0")
        parts[name] = dict(type=e[0:16], uniq=e[16:32], first=f, last=l, slot=i, attrs=e[48:56])
    return dict(cur=cur, alt=alt, first=first, last=last, disk_guid=buf_header[56:72],
                ent_lba=ent_lba, parts=parts)


def run_tool(*args):
    return subprocess.run(
        [sys.executable, "-I", TOOL, *args], capture_output=True, text=True
    )


class ToolOutput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        td = tempfile.TemporaryDirectory()
        cls.addClassCleanup(td.cleanup)
        cls.dir = td.name
        cls.src = os.path.join(td.name, "fwup.img")
        cls.disk_guid, cls.src_len = make_source(cls.src)
        cls.base = os.path.join(td.name, "ufs")
        r = run_tool("--input", cls.src, "--disk-bytes", str(DISK), "--out", cls.base)
        assert r.returncode == 0, r.stderr
        cls.stdout = r.stdout
        cls.img_path = cls.base + ".img"
        with open(cls.base + "-backup-gpt.bin", "rb") as f:
            cls.backup = f.read()
        cls.S = DISK // SS

    def img_at(self, offset, length):
        # The image is ~1.8 GiB; read only the range an assertion needs.
        with open(self.img_path, "rb") as f:
            f.seek(offset)
            return f.read(length)

    def front_gpt(self):
        front = self.img_at(0, 6 * SS)
        return read_gpt(front[SS : SS + 92], front[2 * SS : 6 * SS])

    def test_primary_header_at_4096(self):
        front = self.img_at(0, 6 * SS)
        g = read_gpt(front[SS : SS + 92], front[2 * SS : 2 * SS + 16384])
        self.assertEqual(g["cur"], 1)
        self.assertEqual(g["alt"], self.S - 1)
        self.assertEqual(g["ent_lba"], 2)
        self.assertEqual(g["first"], 6)
        self.assertEqual(g["disk_guid"], self.disk_guid)
        self.assertEqual(front[510:512], b"\x55\xaa")
        self.assertEqual(front[450], 0xEE)

    def test_backup_gpt_and_cross_references(self):
        self.assertEqual(len(self.backup), 5 * SS)
        b = read_gpt(self.backup[4 * SS : 4 * SS + 92], self.backup[: 4 * SS])
        p = self.front_gpt()
        self.assertEqual(b["cur"], self.S - 1)
        self.assertEqual(b["alt"], p["cur"])
        self.assertEqual(p["alt"], b["cur"])
        self.assertEqual(b["ent_lba"], self.S - 5)
        self.assertEqual((b["first"], b["last"]), (p["first"], p["last"]))
        self.assertEqual(b["parts"], p["parts"])
        self.assertIn(f"byte {DISK - 5 * SS}", self.stdout)

    def test_partitions_preserved(self):
        p = self.front_gpt()["parts"]
        self.assertEqual(list(p), [n for n, _, _ in LAYOUT])
        for slot, (name, start, count) in enumerate(LAYOUT):
            self.assertEqual(p[name]["first"] * SS, start * 512, name)
            self.assertEqual(p[name]["uniq"], guid(slot + 1), name)
            self.assertEqual(p[name]["slot"], slot, name)
        self.assertEqual(p["env"]["type"], ESP_TYPE)
        self.assertEqual(p["rootfs-a"]["type"], LINUX_TYPE)
        for name, start, count in LAYOUT[:-1]:
            self.assertEqual((p[name]["last"] + 1) * SS, (start + count) * 512, name)

    def test_attributes_preserved(self):
        p = self.front_gpt()["parts"]
        for name, _, _ in LAYOUT:
            self.assertEqual(p[name]["attrs"], struct.pack("<Q", ATTRS.get(name, 0)), name)

    def test_data_grown_to_last_usable(self):
        g = self.front_gpt()
        self.assertEqual(g["last"], self.S - 6)
        self.assertEqual(g["parts"]["data"]["last"], self.S - 6)
        self.assertEqual(g["parts"]["data"]["first"], 2654208 // 8)

    def test_markers_at_partition_starts(self):
        for name, start, _ in LAYOUT:
            at = start * 512
            self.assertEqual(self.img_at(at, 5 + len(name)), b"MARK-" + name.encode())

    def test_length_and_stale_backup_zeroed(self):
        size = os.path.getsize(self.img_path)
        self.assertEqual(size, self.src_len)
        self.assertEqual(size % SS, 0)
        end = max(s + c for _, s, c in LAYOUT)
        stale = self.img_at((end + 1) * 512, 33 * 512)
        self.assertEqual(stale, bytes(len(stale)))

    def test_full_mode(self):
        base = os.path.join(self.dir, "full")
        r = run_tool("--input", self.src, "--disk-bytes", str(DISK), "--out", base, "--full")
        self.assertEqual(r.returncode, 0, r.stderr)
        path = base + "-full.img"
        self.assertEqual(os.path.getsize(path), DISK)
        with open(path, "rb") as f:
            self.assertEqual(f.read(6 * SS), self.img_at(0, 6 * SS))
            f.seek(DISK - 5 * SS)
            self.assertEqual(f.read(), self.backup)
            at = LAYOUT[3][1] * 512
            f.seek(at)
            self.assertEqual(f.read(10), b"MARK-rootf")


class Rejections(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.dir = td.name
        self.src = os.path.join(td.name, "fwup.img")
        self.out = os.path.join(td.name, "o")

    def rejected(self, disk=DISK, msg=None):
        r = run_tool("--input", self.src, "--disk-bytes", str(disk), "--out", self.out)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertTrue(r.stderr.startswith("error:"), r.stderr)
        if msg:
            self.assertIn(msg, r.stderr)
        self.assertFalse(os.path.exists(self.out + ".img"))

    def test_wrong_name(self):
        layout = list(LAYOUT)
        layout[1] = ("boot", *layout[1][1:])
        make_source(self.src, layout)
        self.rejected(msg="expected")

    def test_wrong_count(self):
        make_source(self.src, LAYOUT[:4])
        self.rejected(msg="expected")

    def test_data_not_last(self):
        layout = [LAYOUT[0], LAYOUT[1], LAYOUT[2], ("data", *LAYOUT[3][1:]), ("rootfs-b", *LAYOUT[4][1:])]
        make_source(self.src, layout)
        self.rejected(msg="not 'data'")

    def test_misaligned_start(self):
        layout = list(LAYOUT)
        layout[1] = ("bootfs", 32768 + 1, 524288 - 1)
        make_source(self.src, layout)
        self.rejected(msg="multiple of 4096")

    def test_partition_inside_gpt_front(self):
        layout = list(LAYOUT)
        layout[0] = ("env", 40, 2008)
        make_source(self.src, layout)
        self.rejected(msg="clobber")

    def test_disk_too_small(self):
        make_source(self.src)
        self.rejected(disk=GIB, msg="too small")

    def test_disk_just_below_data_minimum(self):
        make_source(self.src)
        data_end_sector = (2654208 + 1048576) // 8
        self.rejected(disk=(data_end_sector + 5) * SS, msg="too small")

    def test_disk_not_multiple_of_4096(self):
        make_source(self.src)
        self.rejected(disk=DISK + 512, msg="multiple of 4096")

    def test_unparseable_size(self):
        make_source(self.src)
        r = run_tool("--input", self.src, "--disk-bytes", "lots", "--out", self.out)
        self.assertEqual(r.returncode, 1)

    def test_not_a_gpt(self):
        with open(self.src, "wb") as f:
            f.write(bytes(MIB))
        self.rejected(msg="MBR")


class OutputAliasesInput(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.dir = td.name
        self.src = os.path.join(td.name, "fwup.img")
        make_source(self.src)
        self.before = self.digest()

    def digest(self):
        h = hashlib.sha256()
        with open(self.src, "rb") as f:
            while chunk := f.read(MIB):
                h.update(chunk)
        return h.hexdigest()

    def assert_refused(self, out, *extra):
        r = run_tool("--input", self.src, "--disk-bytes", str(DISK), "--out", out, *extra)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("same file as --input", r.stderr)
        self.assertEqual(self.digest(), self.before)

    def test_same_path(self):
        self.assert_refused(self.src[: -len(".img")])

    def test_symlink_to_input(self):
        os.symlink(self.src, os.path.join(self.dir, "ln.img"))
        self.assert_refused(os.path.join(self.dir, "ln"))

    def test_hard_link_to_input(self):
        os.link(self.src, os.path.join(self.dir, "hl.img"))
        self.assert_refused(os.path.join(self.dir, "hl"))

    def test_full_mode_target(self):
        os.link(self.src, os.path.join(self.dir, "hf-full.img"))
        self.assert_refused(os.path.join(self.dir, "hf"), "--full")


class OutputsAliasEachOther(unittest.TestCase):
    """Writing the backup through an alias of the image would truncate the
    image to 20480 bytes and still exit 0."""

    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.dir = td.name
        self.src = os.path.join(td.name, "fwup.img")
        make_source(self.src)
        self.out = os.path.join(td.name, "o")
        with open(self.out + ".img", "wb") as f:
            f.write(b"existing")

    def assert_refused(self):
        r = run_tool("--input", self.src, "--disk-bytes", str(DISK), "--out", self.out)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("are the same file", r.stderr)
        with open(self.out + ".img", "rb") as f:
            self.assertEqual(f.read(), b"existing")

    def test_backup_symlinked_to_image(self):
        os.symlink(self.out + ".img", self.out + "-backup-gpt.bin")
        self.assert_refused()

    def test_backup_hard_linked_to_image(self):
        os.link(self.out + ".img", self.out + "-backup-gpt.bin")
        self.assert_refused()


if __name__ == "__main__":
    unittest.main()
