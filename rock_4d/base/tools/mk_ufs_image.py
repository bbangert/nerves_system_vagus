#!/usr/bin/env python3
"""Rewrite a 512-LBA fwup GPT image for a 4096-byte-sector (4Kn) UFS module.

fwup hardwires 512-byte blocks: its GPT sits at byte 512 with 512-byte LBAs,
which U-Boot and the kernel cannot read on a 4Kn LUN. Every partition in the
fwup layout is MiB-aligned, so only the GPT needs regenerating: each
partition keeps its byte range (and unique/type GUIDs, which U-Boot's env
lookup and root=PARTUUID= depend on); `data` is grown to fill the module.
The on-device expand-data task does 512-byte LBA math and must not run on a
4Kn disk, so generation-time sizing replaces it.

Usage:
    mk_ufs_image.py --input fwup.img --disk-bytes $(blockdev --getsize64 /dev/sdX) --out ufs
    mk_ufs_image.py --input fwup.img --disk-bytes 137438953472 --out ufs --full

--disk-bytes must be the device's exact byte count; K/M/G/T suffixes are
binary (128G is 128 GiB, more than a "128 GB" module holds). The backup
GPT lands at the true end of the disk, so an approximate figure would put
it somewhere the firmware never looks. The USB reader's reported
logical sector size (`blockdev --getss`) is irrelevant: the image is a byte
stream with the GPT at byte 4096 regardless of how the reader presents it.

Default output:
    <out>.img             MBR + primary GPT + partition data through the end
                          of the source image (or rootfs-b, if larger).
    <out>-backup-gpt.bin  backup entries + backup header; `dd` it at the byte
                          offset printed at the end (disk_bytes - 5*4096).
--full emits one sparse <out>-full.img exactly --disk-bytes long instead.
"""

import argparse
import binascii
import os
import re
import struct
import sys

SRC_SECTOR = 512
DST_SECTOR = 4096

GPT_ENTRY_SIZE = 128
GPT_NUM_ENTRIES = 128
GPT_ENTRIES_BYTES = GPT_NUM_ENTRIES * GPT_ENTRY_SIZE
DST_ENTRIES_SECTORS = GPT_ENTRIES_BYTES // DST_SECTOR  # 4 at 4Kn

# LBA0 protective MBR, LBA1 primary header, LBA2-5 entries.
DST_FIRST_USABLE = 2 + DST_ENTRIES_SECTORS
DST_FRONT_BYTES = DST_FIRST_USABLE * DST_SECTOR
BACKUP_SECTORS = DST_ENTRIES_SECTORS + 1

# In on-disk (start) order; the order check also pins `data` as last.
EXPECTED_PARTITIONS = ["env", "bootfs", "rootfs-a", "rootfs-b", "data"]

COPY_CHUNK = 4 * 1024 * 1024


class GptError(ValueError):
    pass


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def parse_size(text: str) -> int:
    """K/M/G/T suffixes (optionally with i/B) are powers of 1024."""
    m = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*([KMGTkmgt]?)i?[Bb]?\s*", text)
    if not m:
        raise ValueError(f"cannot parse size {text!r}")
    number, unit = m.groups()
    value = float(number)
    if unit:
        value *= 1024 ** ("KMGT".index(unit.upper()) + 1)
    return int(round(value))


def _decode_name(raw: bytes) -> str:
    return raw.decode("utf-16le").rstrip("\x00")


def _encode_name(name: str, field_len: int) -> bytes:
    raw = name.encode("utf-16le")
    if len(raw) > field_len:
        raise GptError(f"partition name {name!r} does not fit in {field_len} bytes")
    return raw + b"\x00" * (field_len - len(raw))


def parse_gpt_header(hdr_bytes: bytes) -> dict:
    if hdr_bytes[0:8] != b"EFI PART":
        raise GptError(f"bad GPT signature: {hdr_bytes[0:8]!r}")

    header_size = struct.unpack_from("<I", hdr_bytes, 12)[0]
    if header_size < 92 or header_size > len(hdr_bytes):
        raise GptError(f"implausible GPT header_size {header_size}")

    stored_crc = struct.unpack_from("<I", hdr_bytes, 16)[0]
    zeroed = bytearray(hdr_bytes[:header_size])
    struct.pack_into("<I", zeroed, 16, 0)
    calc_crc = crc32(bytes(zeroed))
    if calc_crc != stored_crc:
        raise GptError(
            f"GPT header CRC mismatch: stored=0x{stored_crc:08x} calc=0x{calc_crc:08x}"
        )

    current_lba, backup_lba, first_usable, last_usable = struct.unpack_from(
        "<QQQQ", hdr_bytes, 24
    )
    disk_guid = bytes(hdr_bytes[56:72])
    entries_lba, num_entries, entry_size, entries_crc = struct.unpack_from(
        "<QIII", hdr_bytes, 72
    )

    return dict(
        current_lba=current_lba,
        backup_lba=backup_lba,
        first_usable=first_usable,
        last_usable=last_usable,
        disk_guid=disk_guid,
        entries_lba=entries_lba,
        num_entries=num_entries,
        entry_size=entry_size,
        entries_crc=entries_crc,
    )


def parse_entries(entries_bytes: bytes, num_entries: int, entry_size: int) -> list:
    partitions = []
    for slot in range(num_entries):
        e = entries_bytes[slot * entry_size : (slot + 1) * entry_size]
        type_guid = bytes(e[0:16])
        if type_guid == b"\x00" * 16:
            continue
        first_lba, last_lba, attrs = struct.unpack_from("<QQQ", e, 32)
        partitions.append(
            dict(
                slot=slot,
                type_guid=type_guid,
                uniq_guid=bytes(e[16:32]),
                first_lba=first_lba,
                last_lba=last_lba,
                attrs=attrs,
                name=_decode_name(e[56:entry_size]),
            )
        )
    return partitions


def parse_gpt(data: bytes, sector_size: int) -> dict:
    """Also used to round-trip the generated 4Kn front as a self-check."""
    if len(data) < 6 * sector_size:
        raise GptError("input too short to contain a GPT")

    mbr = data[0:sector_size]
    if mbr[510:512] != b"\x55\xaa":
        raise GptError("missing MBR boot signature (0x55AA)")
    ptype = mbr[450]
    if ptype != 0xEE:
        raise GptError(f"not a protective MBR (partition type 0x{ptype:02x})")

    header = parse_gpt_header(data[sector_size : sector_size + 92])

    entries_start = header["entries_lba"] * sector_size
    entries_len = header["num_entries"] * header["entry_size"]
    entries_bytes = data[entries_start : entries_start + entries_len]
    if len(entries_bytes) != entries_len:
        raise GptError("partition entries array runs past end of input")

    calc = crc32(entries_bytes)
    if calc != header["entries_crc"]:
        raise GptError(
            "GPT entries CRC mismatch: stored=0x%08x calc=0x%08x"
            % (header["entries_crc"], calc)
        )

    partitions = parse_entries(entries_bytes, header["num_entries"], header["entry_size"])
    return dict(header, sector_size=sector_size, partitions=partitions)


def validate_source(src: dict) -> None:
    parts = sorted(src["partitions"], key=lambda p: p["first_lba"])
    names = [p["name"] for p in parts]
    if names != EXPECTED_PARTITIONS:
        if sorted(names) == sorted(EXPECTED_PARTITIONS) and names[-1] != "data":
            raise GptError(
                f"partition {names[-1]!r} has the highest start offset, not 'data' -- "
                "refusing to guess which partition to expand to fill the module"
            )
        raise GptError(
            f"source GPT partitions (by offset) are {names!r}, expected "
            f"{EXPECTED_PARTITIONS!r}. This tool is tied to the fwup layout; "
            "update it if the layout changed."
        )

    prev_end = 0
    for p in parts:
        start_byte = p["first_lba"] * SRC_SECTOR
        end_byte = (p["last_lba"] + 1) * SRC_SECTOR
        if start_byte % DST_SECTOR != 0 or end_byte % DST_SECTOR != 0:
            raise GptError(
                f"partition {p['name']!r} byte range [{start_byte}, {end_byte}) "
                f"is not a multiple of {DST_SECTOR} -- cannot translate to 4Kn LBAs"
            )
        if start_byte < DST_FRONT_BYTES:
            raise GptError(
                f"partition {p['name']!r} starts at byte {start_byte}, inside the "
                f"{DST_FRONT_BYTES}-byte 4Kn GPT front -- the output would clobber "
                "its head. The fwup layout changed; update this tool."
            )
        if start_byte < prev_end:
            raise GptError(f"partition {p['name']!r} overlaps its predecessor")
        prev_end = end_byte


def translate_partitions(src_partitions: list, disk_bytes: int) -> tuple:
    S = disk_bytes // DST_SECTOR
    last_usable_new = S - DST_FIRST_USABLE

    translated = []
    for p in sorted(src_partitions, key=lambda p: p["first_lba"]):
        new_first = p["first_lba"] * SRC_SECTOR // DST_SECTOR
        new_last = (p["last_lba"] + 1) * SRC_SECTOR // DST_SECTOR - 1
        translated.append(dict(p, new_first=new_first, new_last=new_last))

    data = translated[-1]
    # data may only grow: the image carries source bytes through its minimum
    # extent, so a smaller module would also let the dd run past the device.
    if last_usable_new < data["new_last"]:
        raise GptError(
            f"--disk-bytes {disk_bytes} is too small: LastUsableLBA {last_usable_new} "
            f"is below the data partition's minimum end LBA {data['new_last']}"
        )

    data["new_last"] = last_usable_new
    return translated, S, last_usable_new


def build_protective_mbr(total_sectors: int) -> bytes:
    mbr = bytearray(DST_SECTOR)
    num_sectors_field = min(total_sectors - 1, 0xFFFFFFFF)
    entry = struct.pack(
        "<B3sB3sII", 0x00, b"\x00\x02\x00", 0xEE, b"\xff\xff\xff", 1, num_sectors_field
    )
    mbr[446 : 446 + len(entry)] = entry
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def build_gpt_header(
    current_lba, backup_lba, first_usable, last_usable, disk_guid, entries_lba, entries_crc
) -> bytes:
    header = bytearray(92)
    header[0:8] = b"EFI PART"
    struct.pack_into("<I", header, 8, 0x00010000)
    struct.pack_into("<I", header, 12, 92)
    struct.pack_into("<Q", header, 24, current_lba)
    struct.pack_into("<Q", header, 32, backup_lba)
    struct.pack_into("<Q", header, 40, first_usable)
    struct.pack_into("<Q", header, 48, last_usable)
    header[56:72] = disk_guid
    struct.pack_into("<Q", header, 72, entries_lba)
    struct.pack_into("<I", header, 80, GPT_NUM_ENTRIES)
    struct.pack_into("<I", header, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", header, 88, entries_crc)
    struct.pack_into("<I", header, 16, crc32(bytes(header)))
    return bytes(header)


def build_entries_bytes(translated: list) -> bytes:
    buf = bytearray(GPT_ENTRIES_BYTES)
    for p in translated:
        e = bytearray(GPT_ENTRY_SIZE)
        e[0:16] = p["type_guid"]
        e[16:32] = p["uniq_guid"]
        struct.pack_into("<QQQ", e, 32, p["new_first"], p["new_last"], p["attrs"])
        e[56:GPT_ENTRY_SIZE] = _encode_name(p["name"], GPT_ENTRY_SIZE - 56)
        buf[p["slot"] * GPT_ENTRY_SIZE : (p["slot"] + 1) * GPT_ENTRY_SIZE] = e
    return bytes(buf)


def build_new_gpt(disk_guid: bytes, translated: list, S: int) -> dict:
    entries_bytes = build_entries_bytes(translated)
    entries_crc = crc32(entries_bytes)
    last_usable = S - DST_FIRST_USABLE

    primary_header = build_gpt_header(
        1, S - 1, DST_FIRST_USABLE, last_usable, disk_guid, 2, entries_crc
    )
    backup_header = build_gpt_header(
        S - 1, 1, DST_FIRST_USABLE, last_usable, disk_guid, S - BACKUP_SECTORS, entries_crc
    )

    front = bytearray(DST_FRONT_BYTES)
    front[0:DST_SECTOR] = build_protective_mbr(S)
    front[DST_SECTOR : DST_SECTOR + len(primary_header)] = primary_header
    front[2 * DST_SECTOR : 2 * DST_SECTOR + len(entries_bytes)] = entries_bytes

    backup_gpt = bytearray(BACKUP_SECTORS * DST_SECTOR)
    backup_gpt[0 : len(entries_bytes)] = entries_bytes
    hdr_off = DST_ENTRIES_SECTORS * DST_SECTOR
    backup_gpt[hdr_off : hdr_off + len(backup_header)] = backup_header

    return dict(
        front=bytes(front),
        backup_gpt=bytes(backup_gpt),
        entries_bytes=entries_bytes,
        entries_crc=entries_crc,
        primary_header=primary_header,
        backup_header=backup_header,
        last_usable=last_usable,
    )


def self_verify(built: dict, disk_guid: bytes, translated: list, S: int) -> None:
    for label, hdr in (("primary", built["primary_header"]), ("backup", built["backup_header"])):
        parsed = parse_gpt_header(hdr)
        if parsed["disk_guid"] != disk_guid:
            raise GptError(f"self-check: {label} header disk GUID does not match source")
        if parsed["entries_crc"] != crc32(built["entries_bytes"]):
            raise GptError(f"self-check: {label} header entries CRC does not match")

    backup = built["backup_gpt"]
    if backup[: GPT_ENTRIES_BYTES] != built["entries_bytes"]:
        raise GptError("self-check: backup entries differ from primary")
    if parse_gpt_header(backup[DST_ENTRIES_SECTORS * DST_SECTOR :][:92])["current_lba"] != S - 1:
        raise GptError("self-check: backup header is not at the last LBA")

    rt = parse_gpt(built["front"], DST_SECTOR)
    if rt["disk_guid"] != disk_guid:
        raise GptError("self-check: round-trip disk GUID mismatch")
    if rt["first_usable"] != DST_FIRST_USABLE or rt["last_usable"] != built["last_usable"]:
        raise GptError("self-check: round-trip usable LBA mismatch")
    if rt["backup_lba"] != S - 1:
        raise GptError("self-check: round-trip BackupLBA mismatch")

    got = {
        (p["slot"], p["name"], p["first_lba"], p["last_lba"], p["uniq_guid"], p["type_guid"], p["attrs"])
        for p in rt["partitions"]
    }
    want = {
        (p["slot"], p["name"], p["new_first"], p["new_last"], p["uniq_guid"], p["type_guid"], p["attrs"])
        for p in translated
    }
    if got != want:
        raise GptError("self-check: round-trip partitions mismatch")


def copy_body(src, dst, start: int, end: int, blank: tuple) -> None:
    """Copy [start, end) of src to the same offsets in dst, zero-padding past
    src's EOF, zeroing the `blank` byte range, and seeking over all-zero
    chunks so the output stays sparse."""
    blank_lo, blank_hi = blank
    pos = start
    src.seek(start)
    while pos < end:
        n = min(COPY_CHUNK, end - pos)
        chunk = src.read(n)
        if len(chunk) < n:
            chunk += b"\x00" * (n - len(chunk))
        lo, hi = max(pos, blank_lo), min(pos + n, blank_hi)
        if lo < hi:
            chunk = bytearray(chunk)
            chunk[lo - pos : hi - pos] = b"\x00" * (hi - lo)
        if chunk.count(0) != n:
            dst.seek(pos)
            dst.write(chunk)
        pos += n


def print_summary(translated, S, last_usable, out_prefix, full, disk_bytes, out_len):
    print("Partition translation (512-byte-LBA source -> 4096-byte-LBA target):")
    print(f"  {'name':<10} {'old first':>12} {'old last':>12}   {'new first':>12} {'new last':>12}")
    for p in translated:
        print(
            f"  {p['name']:<10} {p['first_lba']:>12} {p['last_lba']:>12}   "
            f"{p['new_first']:>12} {p['new_last']:>12}"
        )
    print()
    print("GPT geometry (target):")
    print(f"  sector size:          {DST_SECTOR} bytes")
    print(f"  disk sectors (S):     {S}")
    print(f"  FirstUsableLBA:       {DST_FIRST_USABLE}")
    print(f"  LastUsableLBA:        {last_usable}")
    print(f"  backup entries LBA:   {S - BACKUP_SECTORS}")
    print(f"  backup header LBA:    {S - 1}")
    print(f"  image length:         {out_len} bytes")
    print()
    backup_offset = disk_bytes - BACKUP_SECTORS * DST_SECTOR
    if full:
        print(f"Write {out_prefix}-full.img to the device from byte 0.")
    else:
        print(f"Write {out_prefix}.img to the device from byte 0, then the backup GPT at byte {backup_offset}:")
        print(
            f"  dd if={out_prefix}-backup-gpt.bin of=/dev/sdX bs=4096 "
            f"seek={backup_offset} oflag=seek_bytes conv=fsync"
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", required=True, help="512-LBA image from `fwup -a -t complete`")
    ap.add_argument(
        "--disk-bytes",
        required=True,
        help="exact module size in bytes (`blockdev --getsize64`), or with a K/M/G/T suffix",
    )
    ap.add_argument("--out", required=True, help="output path prefix")
    ap.add_argument(
        "--full",
        action="store_true",
        help="emit one sparse <out>-full.img of exactly --disk-bytes instead of .img + backup GPT",
    )
    args = ap.parse_args()

    try:
        disk_bytes = parse_size(args.disk_bytes)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if disk_bytes % DST_SECTOR != 0:
        print(
            f"error: --disk-bytes {args.disk_bytes} ({disk_bytes} bytes) is not a multiple of "
            f"{DST_SECTOR}; pass the exact figure from `blockdev --getsize64`",
            file=sys.stderr,
        )
        return 1

    # Header + entries of a 512-LBA GPT end by LBA 34; 1 MiB is ample.
    with open(args.input, "rb") as f:
        head = f.read(1024 * 1024)
        src_len = f.seek(0, 2)

    try:
        src = parse_gpt(head, SRC_SECTOR)
        validate_source(src)
        translated, S, last_usable = translate_partitions(src["partitions"], disk_bytes)
        built = build_new_gpt(src["disk_guid"], translated, S)
        self_verify(built, src["disk_guid"], translated, S)

        # fwup's stale 512-LBA backup GPT (entries, then header at backup_lba)
        # sits just past the data minimum, with MiB padding after it, so it is
        # located from the header rather than assumed to be at the file's end.
        stale_hdr_pos = src["backup_lba"] * SRC_SECTOR
        if stale_hdr_pos + SRC_SECTOR > src_len:
            raise GptError("source image is truncated before its own backup GPT")
        with open(args.input, "rb") as f:
            f.seek(stale_hdr_pos)
            stale = parse_gpt_header(f.read(92))
        if stale["current_lba"] != src["backup_lba"]:
            raise GptError("source backup GPT header is not at the primary's BackupLBA")
        stale_start = stale["entries_lba"] * SRC_SECTOR
        stale_end = stale_hdr_pos + SRC_SECTOR
        if stale_start < DST_FRONT_BYTES:
            raise GptError("source backup GPT overlaps the 4Kn GPT front")

        rootfs_b = next(p for p in translated if p["name"] == "rootfs-b")
        out_len = max((rootfs_b["new_last"] + 1) * DST_SECTOR, src_len)
        out_len = -(-out_len // DST_SECTOR) * DST_SECTOR
        backup_offset = disk_bytes - BACKUP_SECTORS * DST_SECTOR
        if out_len > backup_offset:
            raise GptError(
                f"image length {out_len} would overlap the backup GPT at {backup_offset}; "
                "--disk-bytes is too small"
            )
    except GptError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    # "wb" truncates, so an output aliasing the input or another output
    # destroys it and still reports success; realpath covers symlinks,
    # samefile covers hard links (only checkable once both exist).
    def same(a, b):
        return os.path.realpath(a) == os.path.realpath(b) or (
            os.path.exists(a) and os.path.exists(b) and os.path.samefile(a, b)
        )

    outputs = (
        [f"{args.out}-full.img"]
        if args.full
        else [f"{args.out}.img", f"{args.out}-backup-gpt.bin"]
    )
    for i, out in enumerate(outputs):
        if same(out, args.input):
            print(f"error: output {out} is the same file as --input", file=sys.stderr)
            return 1
        for other in outputs[i + 1 :]:
            if same(out, other):
                print(f"error: outputs {out} and {other} are the same file", file=sys.stderr)
                return 1

    blank = (stale_start, stale_end)
    out_path = f"{args.out}-full.img" if args.full else f"{args.out}.img"
    with open(args.input, "rb") as src_f, open(out_path, "wb") as dst:
        dst.truncate(disk_bytes if args.full else out_len)
        dst.write(built["front"])
        copy_body(src_f, dst, DST_FRONT_BYTES, out_len, blank)
        if args.full:
            dst.seek(backup_offset)
            dst.write(built["backup_gpt"])
        else:
            dst.truncate(out_len)

    if args.full:
        print(f"Wrote {out_path} ({disk_bytes} bytes, sparse)\n")
    else:
        backup_path = f"{args.out}-backup-gpt.bin"
        with open(backup_path, "wb") as f:
            f.write(built["backup_gpt"])
        print(f"Wrote {out_path} and {backup_path}\n")

    print_summary(translated, S, last_usable, args.out, args.full, disk_bytes, out_len)
    return 0


if __name__ == "__main__":
    sys.exit(main())
