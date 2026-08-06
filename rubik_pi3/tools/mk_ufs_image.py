#!/usr/bin/env python3
"""Transform a 512-LBA fwup GPT image into a 4096-byte-sector (4Kn) UFS image.

Ported from the Q6A port's tools/mk_ufs_image.py (see
docs/dragon-q6a-flashing.md's UFS section for the full runbook this
originated from). There, UFS was one of two boot-disk options alongside
NVMe; on Rubik Pi 3 the onboard 128 GB UFS module is the PRIMARY boot disk
(no NVMe-boot alternative -- the M.2 slot here is data/expansion only), so
every board this ships on needs this 4Kn regeneration step, flashed via EDL.

Background: the onboard UFS module reports 4096-byte logical sectors, but
fwup is hardwired to 512-byte blocks everywhere -- both in its GPT writer and
in its FatFs implementation. It turns out that is only a problem for the GPT
structures themselves:

  * EDK2's FatPkg FAT driver only checks the BPB SectorSize field is a power
    of two and does all I/O through byte-addressed DiskIo, so a 512-BPB FAT
    filesystem mounts fine on a 4Kn block device.
  * GRUB only ever `load_env`s the ESP (read-only) and its FAT code is also
    BPB-driven, not device-sector-driven.
  * fwup's on-device A/B upgrade tasks (upgrade.a/b in fwup.conf) only touch
    uboot-env and raw_write/trim, all addressed by byte offset, and those
    offsets are MiB-aligned in fwup_include/fwup-common.conf -- every one of
    them is already a multiple of 4096.
  * The kernel never mounts the FAT partitions; root=PARTUUID= only needs a
    valid GPT, not a particular sector size.

So the `.fw` file and every on-device code path are IDENTICAL between the
NVMe and UFS variants. The only delta is this EDL disk image: the GPT (and
only the GPT) must be regenerated for 4096-byte LBAs. This script does that
by parsing the 512-LBA GPT that `fwup -a -t complete` produces, translating
every partition's byte range (unchanged) into 4096-byte LBA numbers, and
resizing the data partition to fill the target module -- fwup's on-device
`expand-data` fwup-ops task calls gpt_write() itself and hardcodes 512-byte
LBA math, so it would corrupt a 4Kn GPT; running it on a UFS-flashed board is
disallowed, and generation-time sizing here replaces it.

Usage:
    mk_ufs_image.py --input rubik_pi3.img --disk-bytes 128G --out rubik_pi3_ufs
    mk_ufs_image.py --input rubik_pi3.img --disk-bytes 137438953472 \
        --out rubik_pi3_ufs --full

Default output (two pieces, for edl-ng's write-sector):
    <out>.img              MBR + primary GPT + the source's partition data,
                            sized to just past the data partition's minimum.
    <out>-backup-gpt.bin   backup partition-entries + backup GPT header,
                            written at the printed LBA (disk sectors - 5).

--full instead emits a single <out>-full.img sparse file exactly
--disk-bytes long, with the backup GPT written at the disk's true last
sectors. EDL-writing a full 100+ GiB image is slow; the two-piece flow above
is preferred (an `xz` of the sparse full image is also small, for the record,
but writing it to the device is not).
"""

import argparse
import binascii
import struct
import sys

SRC_SECTOR = 512  # fwup's hardwired GPT/FAT block size
DST_SECTOR = 4096  # UFS module logical sector size

GPT_ENTRY_SIZE = 128
GPT_NUM_ENTRIES = 128
GPT_ENTRIES_BYTES = GPT_NUM_ENTRIES * GPT_ENTRY_SIZE  # 16384

# Sectors of entries at DST_SECTOR: 16384 / 4096 == 4, exactly -- no padding
# needed inside the entries region, unlike the 512-byte-sector case (32
# sectors) that fwup itself uses.
DST_ENTRIES_SECTORS = GPT_ENTRIES_BYTES // DST_SECTOR
assert GPT_ENTRIES_BYTES % DST_SECTOR == 0

# New front layout: LBA0 protective MBR, LBA1 primary header, LBA2-5 entries.
DST_FIRST_USABLE = 2 + DST_ENTRIES_SECTORS  # == 6
DST_FRONT_SECTORS = DST_FIRST_USABLE  # sectors 0..5, i.e. the front image size
DST_FRONT_BYTES = DST_FRONT_SECTORS * DST_SECTOR  # 24576

EXPECTED_PARTITION_NAMES = {"config", "efi", "rootfs-a", "rootfs-b", "data"}



class GptError(ValueError):
    """A source or generated GPT failed validation."""


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def parse_size(text: str) -> int:
    """Parse a size like "128G", "119.2GiB", or a plain byte count.

    K/M/G/T (with or without an "i" and/or trailing "B") are all treated as
    powers of 1024, per the CLI contract. The result is rounded to the
    nearest whole byte -- callers must still check 4096-divisibility
    themselves, since a human-typed approximate capacity (e.g. "119.2GiB"
    for a "128GB"-branded module) is not guaranteed to land on a sector
    boundary; the real, exact byte count should come from `edl-ng printgpt`.
    """
    import re

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
    """Validate and decode a 92-byte GPT header. Raises GptError on any
    signature/CRC mismatch."""
    if hdr_bytes[0:8] != b"EFI PART":
        raise GptError(f"bad GPT signature: {hdr_bytes[0:8]!r}")

    header_size = struct.unpack_from("<I", hdr_bytes, 12)[0]
    if header_size > len(hdr_bytes):
        raise GptError(f"header_size {header_size} exceeds available header bytes")

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
    """Decode the non-empty entries of a partition-entries array. Returns a
    list of dicts in ascending slot order."""
    partitions = []
    for slot in range(num_entries):
        e = entries_bytes[slot * entry_size : (slot + 1) * entry_size]
        type_guid = bytes(e[0:16])
        if type_guid == b"\x00" * 16:
            continue
        uniq_guid = bytes(e[16:32])
        first_lba, last_lba, attrs = struct.unpack_from("<QQQ", e, 32)
        name = _decode_name(e[56:entry_size])
        partitions.append(
            dict(
                slot=slot,
                type_guid=type_guid,
                uniq_guid=uniq_guid,
                first_lba=first_lba,
                last_lba=last_lba,
                attrs=attrs,
                name=name,
            )
        )
    return partitions


def parse_gpt(data: bytes, sector_size: int) -> dict:
    """Parse and fully validate a protective-MBR + primary-GPT image at the
    given sector size. Used both for the 512-byte-sector source image and,
    as a round-trip self-check, for the 4096-byte-sector image this script
    generates."""
    if len(data) < 6 * sector_size:
        raise GptError("input too short to contain a GPT")

    mbr = data[0:sector_size]
    if mbr[510:512] != b"\x55\xaa":
        raise GptError("missing MBR boot signature (0x55AA)")
    pe = mbr[446:462]
    _status, _chs1, ptype, _chs2, pe_first_lba, pe_num_sectors = struct.unpack(
        "<B3sB3sII", pe
    )
    if ptype != 0xEE:
        raise GptError(f"not a protective MBR (partition type 0x{ptype:02x})")

    hdr_bytes = data[sector_size : sector_size + 92]
    header = parse_gpt_header(hdr_bytes)

    entries_start = header["entries_lba"] * sector_size
    entries_len = header["num_entries"] * header["entry_size"]
    entries_bytes = data[entries_start : entries_start + entries_len]
    if len(entries_bytes) != entries_len:
        raise GptError("partition entries array runs past end of input")

    calc_entries_crc = crc32(entries_bytes)
    if calc_entries_crc != header["entries_crc"]:
        raise GptError(
            "GPT entries CRC mismatch: stored=0x%08x calc=0x%08x"
            % (header["entries_crc"], calc_entries_crc)
        )

    partitions = parse_entries(entries_bytes, header["num_entries"], header["entry_size"])

    return dict(
        header,
        sector_size=sector_size,
        mbr_first_lba=pe_first_lba,
        mbr_num_sectors=pe_num_sectors,
        partitions=partitions,
    )


def validate_source(src: dict) -> None:
    names = {p["name"] for p in src["partitions"]}
    if names != EXPECTED_PARTITION_NAMES or len(src["partitions"]) != 5:
        raise GptError(
            "source GPT does not have the expected 5 partitions "
            f"{sorted(EXPECTED_PARTITION_NAMES)!r}; found {sorted(names)!r}. "
            "This script is tied to the current fwup_include/fwup-common.conf "
            "layout -- update it if the layout has changed."
        )

    for p in src["partitions"]:
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
                f"{DST_FRONT_BYTES}-byte 4Kn GPT front this tool writes -- the "
                "output would clobber its head. The fwup layout has changed; "
                "update this tool."
            )


def translate_partitions(src_partitions: list, disk_bytes: int) -> tuple:
    """Translate every source partition's byte range into 4096-byte LBAs,
    and resize the "data" partition to fill the target disk. Returns
    (translated_partitions, S, last_usable_new)."""
    # Floor disk_bytes before doing any LBA arithmetic with it: too-small a
    # value makes S (and thus last_usable_new = S - 6) tiny or negative,
    # which would otherwise only surface later as a confusing negative-LBA
    # error. The real floor is the source image's own partition-content
    # extent (the highest partition end byte, i.e. what the source actually
    # needs); fall back to the tool's structural minimum -- its 4Kn front
    # region plus the 5-sector backup GPT it writes at the tail -- if for
    # some reason no partitions were parsed.
    structural_floor = DST_FRONT_BYTES + 5 * DST_SECTOR
    if src_partitions:
        src_extent = max((p["last_lba"] + 1) * SRC_SECTOR for p in src_partitions)
    else:
        src_extent = 0
    min_disk_bytes = max(structural_floor, src_extent)
    if disk_bytes < min_disk_bytes:
        raise GptError(
            f"--disk-bytes {disk_bytes} is too small: this tool needs at least "
            f"{min_disk_bytes} bytes ({DST_FRONT_BYTES}-byte front region + "
            f"{5 * DST_SECTOR}-byte backup GPT, and at least enough to cover the "
            f"source image's partition content, which extends to byte {src_extent})"
        )

    S = disk_bytes // DST_SECTOR
    last_usable_new = S - 6

    translated = []
    data_idx = None
    max_start_byte = -1
    for p in src_partitions:
        start_byte = p["first_lba"] * SRC_SECTOR
        end_byte = (p["last_lba"] + 1) * SRC_SECTOR
        new_first = start_byte // DST_SECTOR
        new_last = end_byte // DST_SECTOR - 1
        translated.append(dict(p, new_first=new_first, new_last=new_last))
        if start_byte > max_start_byte:
            max_start_byte = start_byte
            data_idx = len(translated) - 1

    if translated[data_idx]["name"] != "data":
        raise GptError(
            "the partition with the highest starting offset is "
            f"{translated[data_idx]['name']!r}, not 'data' -- refusing to "
            "guess which partition to expand to fill the module"
        )

    # The data partition may only GROW. The two-piece .img carries the source
    # body through the data partition's minimum extent, so a module whose
    # LastUsableLBA falls short of the translated source end would both
    # shrink /data below the fwup layout's minimum and let the flash write
    # past the end of the device. Fail loudly instead.
    if last_usable_new < translated[data_idx]["new_last"]:
        raise GptError(
            f"--disk-bytes {disk_bytes} is too small: LastUsableLBA {last_usable_new} "
            f"is below the data partition's minimum end LBA "
            f"{translated[data_idx]['new_last']} from the source layout -- "
            "module is not big enough for this image"
        )

    translated[data_idx]["new_last"] = last_usable_new
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
    current_lba: int,
    backup_lba: int,
    first_usable: int,
    last_usable: int,
    disk_guid: bytes,
    entries_lba: int,
    entries_crc: int,
) -> bytes:
    header = bytearray(92)
    header[0:8] = b"EFI PART"
    struct.pack_into("<I", header, 8, 0x00010000)  # revision 1.0
    struct.pack_into("<I", header, 12, 92)  # header size
    # bytes 16:20 (header CRC) filled in below, after zeroing for the calc
    # bytes 20:24 reserved, left zero
    struct.pack_into("<Q", header, 24, current_lba)
    struct.pack_into("<Q", header, 32, backup_lba)
    struct.pack_into("<Q", header, 40, first_usable)
    struct.pack_into("<Q", header, 48, last_usable)
    header[56:72] = disk_guid
    struct.pack_into("<Q", header, 72, entries_lba)
    struct.pack_into("<I", header, 80, GPT_NUM_ENTRIES)
    struct.pack_into("<I", header, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", header, 88, entries_crc)
    hdr_crc = crc32(bytes(header))
    struct.pack_into("<I", header, 16, hdr_crc)
    return bytes(header)


def build_entries_bytes(translated: list) -> bytes:
    buf = bytearray(GPT_ENTRIES_BYTES)
    for p in translated:
        slot = p["slot"]
        e = bytearray(GPT_ENTRY_SIZE)
        e[0:16] = p["type_guid"]
        e[16:32] = p["uniq_guid"]
        struct.pack_into("<QQQ", e, 32, p["new_first"], p["new_last"], p["attrs"])
        e[56:GPT_ENTRY_SIZE] = _encode_name(p["name"], GPT_ENTRY_SIZE - 56)
        buf[slot * GPT_ENTRY_SIZE : (slot + 1) * GPT_ENTRY_SIZE] = e
    return bytes(buf)


def build_new_gpt(disk_guid: bytes, translated: list, S: int) -> dict:
    """Build the new 4Kn front image (MBR + primary header + primary
    entries) and the backup blob (backup entries + backup header),
    self-verifying both before returning."""
    entries_bytes = build_entries_bytes(translated)
    entries_crc = crc32(entries_bytes)

    last_usable = S - 6
    primary_header = build_gpt_header(
        current_lba=1,
        backup_lba=S - 1,
        first_usable=DST_FIRST_USABLE,
        last_usable=last_usable,
        disk_guid=disk_guid,
        entries_lba=2,
        entries_crc=entries_crc,
    )
    backup_header = build_gpt_header(
        current_lba=S - 1,
        backup_lba=1,
        first_usable=DST_FIRST_USABLE,
        last_usable=last_usable,
        disk_guid=disk_guid,
        entries_lba=S - 5,
        entries_crc=entries_crc,
    )

    front = bytearray(DST_FRONT_BYTES)
    front[0:DST_SECTOR] = build_protective_mbr(S)
    front[DST_SECTOR : DST_SECTOR + len(primary_header)] = primary_header
    front[2 * DST_SECTOR : 2 * DST_SECTOR + len(entries_bytes)] = entries_bytes

    backup_gpt = bytearray(5 * DST_SECTOR)
    backup_gpt[0 : len(entries_bytes)] = entries_bytes
    backup_gpt[4 * DST_SECTOR : 4 * DST_SECTOR + len(backup_header)] = backup_header

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
    """Re-derive every CRC independently and round-trip the primary GPT
    through parse_gpt() before any file is written. Raises GptError (and
    the caller exits non-zero) on any mismatch."""
    recalced_entries_crc = crc32(built["entries_bytes"])
    if recalced_entries_crc != built["entries_crc"]:
        raise GptError("self-check: entries CRC does not match after rebuild")

    for label, hdr in (("primary", built["primary_header"]), ("backup", built["backup_header"])):
        parsed = parse_gpt_header(hdr)  # raises GptError internally on CRC mismatch
        if parsed["disk_guid"] != disk_guid:
            raise GptError(f"self-check: {label} header disk GUID does not match source")
        if parsed["entries_crc"] != built["entries_crc"]:
            raise GptError(f"self-check: {label} header entries CRC does not match")

    # Round-trip the primary GPT (MBR + header + entries) through the same
    # parser used on the source image.
    roundtrip = parse_gpt(built["front"], DST_SECTOR)
    if roundtrip["disk_guid"] != disk_guid:
        raise GptError("self-check: round-trip parse disk GUID mismatch")
    if roundtrip["first_usable"] != DST_FIRST_USABLE or roundtrip["last_usable"] != built["last_usable"]:
        raise GptError("self-check: round-trip parse FirstUsableLBA/LastUsableLBA mismatch")
    if roundtrip["backup_lba"] != S - 1:
        raise GptError("self-check: round-trip parse BackupLBA mismatch")

    got = {(p["slot"], p["name"], p["first_lba"], p["last_lba"]) for p in roundtrip["partitions"]}
    want = {(p["slot"], p["name"], p["new_first"], p["new_last"]) for p in translated}
    if got != want:
        raise GptError(f"self-check: round-trip partitions mismatch\n  got:  {got}\n  want: {want}")


def print_summary(src_partitions: list, translated: list, S: int, last_usable: int, out_prefix: str, full: bool) -> None:
    by_slot = {p["slot"]: p for p in translated}
    print("Partition translation (512-byte-LBA source -> 4096-byte-LBA target):")
    print(f"  {'name':<10} {'old first':>12} {'old last':>12}   {'new first':>12} {'new last':>12}")
    for p in sorted(by_slot.values(), key=lambda p: p["slot"]):
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
    print(f"  backup entries LBA:   {S - 5}")
    print(f"  backup header LBA:    {S - 1}")
    print()
    if full:
        print("Flash with edl-ng:")
        print(f"  edl-ng --memory ufs write-sector 0 {out_prefix}-full.img --lun 0")
    else:
        print("Flash with edl-ng:")
        print(f"  edl-ng --memory ufs write-sector 0 {out_prefix}.img --lun 0")
        print(f"  edl-ng --memory ufs write-sector {S - 5} {out_prefix}-backup-gpt.bin --lun 0")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", required=True, help="512-LBA image from `fwup -a -t complete`")
    ap.add_argument(
        "--disk-bytes",
        required=True,
        help="Target UFS module capacity in bytes, or with a K/M/G/T (x1024) suffix, e.g. 128G",
    )
    ap.add_argument("--out", required=True, help="Output path prefix")
    ap.add_argument(
        "--full",
        action="store_true",
        help="Emit a single sparse <out>-full.img exactly --disk-bytes long instead of the "
        "two-piece (.img + -backup-gpt.bin) output",
    )
    args = ap.parse_args()

    disk_bytes = parse_size(args.disk_bytes)
    if disk_bytes % DST_SECTOR != 0:
        print(
            f"error: --disk-bytes {args.disk_bytes} ({disk_bytes} bytes) is not a multiple of "
            f"{DST_SECTOR}; pass the exact byte count from `edl-ng printgpt`",
            file=sys.stderr,
        )
        return 1

    with open(args.input, "rb") as f:
        source_data = f.read()

    try:
        src = parse_gpt(source_data, SRC_SECTOR)
        validate_source(src)
        translated, S, last_usable = translate_partitions(src["partitions"], disk_bytes)
        built = build_new_gpt(src["disk_guid"], translated, S)
        self_verify(built, src["disk_guid"], translated, S)
    except GptError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    # Locate the source's own (stale, 512-LBA) backup GPT via the parsed
    # header rather than assuming it sits at the literal end of the file:
    # fwup rounds image files it creates up to a whole MiB, so there can be
    # zero-padding after the real backup GPT (verified empirically against
    # a `fwup -a -t complete` output during this tool's development).
    stale_backup_start = src["backup_lba"] * SRC_SECTOR
    if stale_backup_start < DST_FRONT_BYTES:
        print(
            f"error: source image's backup GPT (BackupLBA {src['backup_lba']}, byte "
            f"{stale_backup_start}) sits before this tool's {DST_FRONT_BYTES}-byte "
            "4Kn front region -- this tool assumes the source's backup GPT is at/near "
            "the end of the image, not near the beginning; refusing to guess which "
            "bytes to zero",
            file=sys.stderr,
        )
        return 1
    stale_backup_len = (src["num_entries"] * src["entry_size"]) + SRC_SECTOR
    if stale_backup_start + stale_backup_len > len(source_data):
        print("error: source image is truncated before its own backup GPT", file=sys.stderr)
        return 1

    if args.full:
        out_path = f"{args.out}-full.img"
        with open(out_path, "wb") as f:
            f.truncate(disk_bytes)
            f.seek(0)
            f.write(built["front"])
            body_end = stale_backup_start
            body = bytearray(source_data[DST_FRONT_BYTES:body_end])
            f.seek(DST_FRONT_BYTES)
            f.write(body)
            backup_offset = (S - 5) * DST_SECTOR
            f.seek(backup_offset)
            f.write(built["backup_gpt"])
        print(f"Wrote {out_path} ({disk_bytes} bytes, sparse)\n")
    else:
        body = bytearray(source_data[DST_FRONT_BYTES:])
        rel_start = stale_backup_start - DST_FRONT_BYTES
        body[rel_start : rel_start + stale_backup_len] = b"\x00" * stale_backup_len

        img_path = f"{args.out}.img"
        with open(img_path, "wb") as f:
            f.write(built["front"])
            f.write(bytes(body))
            total = DST_FRONT_BYTES + len(body)
            pad = (-total) % DST_SECTOR
            if pad:
                f.write(b"\x00" * pad)

        backup_path = f"{args.out}-backup-gpt.bin"
        with open(backup_path, "wb") as f:
            f.write(built["backup_gpt"])

        print(f"Wrote {img_path} and {backup_path}\n")

    print_summary(src["partitions"], translated, S, last_usable, args.out, args.full)
    return 0


if __name__ == "__main__":
    sys.exit(main())
