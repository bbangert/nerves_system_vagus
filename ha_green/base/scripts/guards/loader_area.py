"""Static and dynamic proof that a .fw never writes the stock loader area.

Everything is derived from the resolved meta.conf inside the archive, so the
result covers what fwup will really do, not what the source files suggest.

fwup's block cache (block_cache.c) works in 128 KiB segments aligned to
128 KiB: a write dirties every segment it touches, and each dirty segment
goes back to the disk whole, after reading in the sectors that were not
written; a segment marked trimmed reads in as zeros instead. So the unit
that matters is the segment, not the sectors an action names: gpt_write's
34 front sectors rewrite LBA 0-255, the first 96 KiB of the stock loader
included, with whatever bytes were there.
"""

import csv
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import write_trace  # noqa: E402

SECTOR = 512
SEGMENT = 256  # sectors per fwup cache segment
GPT_LAST = 33
GPT_BACKUP_SECTORS = 33
LOADER_FIRST, LOADER_LAST = 64, 16383
WINDOW_FIRST, WINDOW_LAST = 16384, 32767
# The FIT window may only be written by tasks that lay down a whole disk.
WINDOW_TASKS = ("complete", "install")
MIN_PARTITION_START = WINDOW_LAST + 1

# The only tasks allowed a gpt_write/mbr_write, and so the rewrite of LBA
# 0-255 that comes with it: ones that never run against the eMMC. Exact
# names, so a new task with a gpt_write fails until it is argued for here.
# fwup cannot check which device -d names; each entry says what keeps it off
# the eMMC.
SEGMENT0_TASKS = {
    # SD cards and image files, on a host. complete.refuse-emmc stops it on
    # an eMMC that install wrote; a stock eMMC it cannot recognise.
    "complete": "SD card or image file",
    # Root on the SD, and medium.sd (written only by complete) on the
    # destination.
    "expand-data.sd.a": "the SD card complete wrote",
    "expand-data.sd.b": "the SD card complete wrote",
    # Aimed by green-install-emmc at its scratch file.
    "emmc-gpt.a": "green-install-emmc's scratch file",
    "emmc-gpt.b": "green-install-emmc's scratch file",
}

NO_WRITE = {"info", "error"}
RAW = {"raw_write", "raw_memset", "trim"}
FAT = {
    "fat_attrib", "fat_cp", "fat_mkdir", "fat_mkfs", "fat_mv", "fat_mv!",
    "fat_rm", "fat_rm!", "fat_setlabel", "fat_touch", "fat_write",
}
ENV = {"uboot_clearenv", "uboot_recover", "uboot_setenv", "uboot_unsetenv"}
BANNED = {"path_write", "pipe_write", "execute"}


class Violations(list):
    def add(self, where, msg):
        self.append("%s: %s" % (where, msg))


def split_funlist(body):
    """funlist={N,name,arg...,N,name,...}: N counts the name plus its args."""
    toks = next(csv.reader([body], escapechar="\\"))
    calls, i = [], 0
    while i < len(toks):
        n = int(toks[i])
        calls.append((toks[i + 1], toks[i + 2:i + 1 + n]))
        i += 1 + n
    return calls


def parse_meta(text):
    res, gpts, envs, tasks = {}, {}, {}, {}
    stack = []
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r'^(file-resource|gpt|task|uboot-environment|partition|on-resource)\s+"([^"]*)"\s*\{$', line)
        if m:
            stack.append((m.group(1), m.group(2), {}))
            continue
        m = re.match(r"^(on-init|on-finish|on-error)\s*\{$", line)
        if m:
            stack.append((m.group(1), "", {}))
            continue
        if line == "}":
            kind, name, props = stack.pop()
            if kind == "file-resource":
                res[name] = props
            elif kind == "uboot-environment":
                envs[name] = props
            elif kind == "partition":
                stack[-1][2].setdefault("partitions", []).append(props)
            elif kind == "gpt":
                gpts[name] = props
            elif kind == "task":
                tasks[name] = props
            elif kind in ("on-init", "on-finish", "on-error", "on-resource"):
                stack[-1][2].setdefault("hooks", []).append((kind, name, props))
            continue
        if stack and "=" in line:
            k, v = line.split("=", 1)
            stack[-1][2][k] = v
    return res, gpts, envs, tasks


def num(s):
    return int(s, 0)


def segments(first, last):
    return (first // SEGMENT) * SEGMENT, (last // SEGMENT) * SEGMENT + SEGMENT - 1


def task_calls(t):
    for kind, rname, hp in t.get("hooks", []):
        if "funlist" not in hp:
            continue
        for action, args in split_funlist(hp["funlist"].strip()[1:-1]):
            yield kind, (rname if kind == "on-resource" else None), action, args


def check_static(fw, zf, v):
    meta = zf.read("meta.conf").decode()
    res, gpts, envs, tasks = parse_meta(meta)
    where = os.path.basename(fw)

    layout_end = {}
    for name, g in gpts.items():
        end = 0
        for p in g.get("partitions", []):
            first = num(p["block-offset"])
            end = max(end, first + num(p["block-count"]))
            if first < MIN_PARTITION_START:
                v.add(where, "gpt %s partition '%s' starts at LBA %d, below LBA %d (loader area, FIT window)"
                      % (name, p.get("name", "?"), first, MIN_PARTITION_START))
        layout_end[name] = end

    def seg_rule(tag, first, last, sd_only):
        # eMMC-capable tasks may not dirty any segment below the FIT window;
        # SD-only ones only the segments that hold their GPT write.
        floor = LOADER_FIRST if sd_only else 0
        s0, s1 = segments(first, last)
        if s0 <= LOADER_LAST and s1 >= floor and not (sd_only and last <= GPT_LAST):
            v.add(tag, "dirties fwup cache segment LBA %d-%d, which overlaps LBA %d-%d%s"
                  % (s0, s1, floor, LOADER_LAST,
                     "" if sd_only else "; only SD-only tasks may write there"))

    def span(first, last, task, tag, resource=None):
        if first <= LOADER_LAST and last >= LOADER_FIRST:
            v.add(tag, "writes LBA %d-%d, inside the stock loader area %d-%d"
                  % (first, last, LOADER_FIRST, LOADER_LAST))
        elif first <= LOADER_LAST and last >= GPT_LAST + 1:
            v.add(tag, "writes LBA %d-%d, between the GPT and the loader area" % (first, last))
        elif first <= GPT_LAST:
            v.add(tag, "writes LBA %d-%d, the protective MBR/GPT, outside gpt_write/mbr_write" % (first, last))
        elif first <= WINDOW_LAST and last >= WINDOW_FIRST:
            if not task.startswith(WINDOW_TASKS):
                v.add(tag, "writes LBA %d-%d, the FIT window, outside complete/install" % (first, last))
            elif resource not in (None, "u-boot.itb"):
                v.add(tag, "writes LBA %d-%d, the FIT window, from resource %s" % (first, last, resource))

    for tname, t in tasks.items():
        sd_only = tname in SEGMENT0_TASKS
        for kind, resource, action, args in task_calls(t):
            tag = "%s task %s %s %s(%s)" % (where, tname, kind, action, ",".join(args))
            if action in NO_WRITE:
                continue
            if action in BANNED:
                v.add(tag, "action can write anywhere and cannot be bounded")
            elif action in ("gpt_write", "mbr_write"):
                if action == "gpt_write" and args[0] not in gpts:
                    v.add(tag, "unknown gpt block")
                    continue
                seg_rule(tag, 0, GPT_LAST if action == "gpt_write" else 0, sd_only)
                if action == "gpt_write":
                    # The backup GPT ends the device, which is no smaller
                    # than the layout; its segment must stay clear as well.
                    first = layout_end[args[0]]
                    s0, _ = segments(first, first + GPT_BACKUP_SECTORS)
                    if s0 <= LOADER_LAST:
                        v.add(tag, "backup GPT segment can start at LBA %d, inside LBA 0-%d" % (s0, LOADER_LAST))
            elif action in RAW:
                off = num(args[0])
                if action == "raw_write":
                    if resource is None or resource not in res:
                        v.add(tag, "raw_write outside a known on-resource")
                        continue
                    blocks = (num(res[resource]["length"]) + SECTOR - 1) // SECTOR
                else:
                    blocks = num(args[1])
                if not blocks:
                    continue
                last = off + blocks - 1
                if action == "trim":
                    # A trimmed segment reads in as zeros, so a later partial
                    # write there would put zeros on the disk; with
                    # --enable-trim the device discards it too.
                    s0, s1 = segments(off, last)
                    if s0 <= LOADER_LAST:
                        v.add(tag, "trims fwup cache segment LBA %d-%d, which overlaps LBA 0-%d"
                              % (s0, s1, LOADER_LAST))
                    # Never legitimate: u-boot.itb lives there and a discard
                    # would take U-Boot proper with it. Judged on the segments
                    # the range touches, the conservative side of however fwup
                    # rounds a trim.
                    if s0 <= WINDOW_LAST and s1 >= WINDOW_FIRST:
                        v.add(tag, "trims fwup cache segment LBA %d-%d, which overlaps the FIT window %d-%d"
                              % (s0, s1, WINDOW_FIRST, WINDOW_LAST))
                    continue
                seg_rule(tag, off, last, sd_only)
                span(off, last, tname, tag,
                     resource if action == "raw_write" or resource == "u-boot.itb" else None)
            elif action in FAT:
                off = num(args[0])
                if off < MIN_PARTITION_START:
                    v.add(tag, "FAT offset LBA %d is below LBA %d" % (off, MIN_PARTITION_START))
            elif action in ENV:
                e = envs.get(args[0])
                if e is None:
                    v.add(tag, "unknown uboot-environment block")
                    continue
                off, cnt = num(e["block-offset"]), num(e["block-count"])
                seg_rule(tag, off, off + cnt - 1, sd_only)
                span(off, off + cnt - 1, tname, tag)
            else:
                v.add(tag, "unknown action; add it to the guard after working out what it writes")

    for name in res:
        try:
            head = zf.read("data/" + name)[:4]
        except KeyError:
            continue
        if head == b"RKNS":
            v.add(where, "resource %s is a Rockchip idblock (RKNS); no loader may ship in a .fw" % name)
    return tasks


def without_requirements(zf, out):
    """A copy whose tasks match any destination, so each one can be applied
    to a scratch image on a host."""
    meta = "".join(l for l in zf.read("meta.conf").decode().splitlines(True)
                   if not l.lstrip().startswith("reqlist="))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.writestr("meta.conf", meta)
        for info in zf.infolist():
            if not info.filename.startswith("meta.conf"):
                with zf.open(info) as src, z.open(info.filename, "w") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)


def check_complete(fw, zf, v, fwup, img):
    where = os.path.basename(fw)
    first_byte = (GPT_LAST + 1) * SECTOR
    window_byte = WINDOW_FIRST * SECTOR
    before = len(v)
    pattern = random.Random(7).randbytes(window_byte + (1 << 20))
    with open(img, "wb") as f:
        f.write(pattern)
        f.truncate(3 << 30)
    r = subprocess.run([fwup, "-a", "-q", "-d", img, "-t", "complete", "-i", fw],
                       capture_output=True, text=True)
    if r.returncode:
        v.add(where, "fwup could not apply task complete to a scratch image: %s" % r.stderr.strip())
        return False
    with open(img, "rb") as f:
        f.seek(first_byte)
        after = f.read(window_byte - first_byte)
        fit = f.read(4096)
    if after != pattern[first_byte:window_byte]:
        idx = next(i for i in range(len(after)) if after[i] != pattern[first_byte + i])
        lba = (first_byte + idx) // SECTOR
        v.add(where, "task complete changed byte %d (LBA %d) below 8 MiB" % (first_byte + idx, lba))
    if fit[:4] != b"\xd0\x0d\xfe\xed":
        v.add(where, "no FIT magic at 8 MiB after task complete")
    elif "data/u-boot.itb" in zf.namelist():
        itb = zf.read("data/u-boot.itb")
        with open(img, "rb") as f:
            f.seek(window_byte)
            if f.read(len(itb)) != itb:
                v.add(where, "bytes at 8 MiB are not the u-boot.itb of this .fw")
    if len(v) == before:
        print("check-loader-area: %s dynamic: bytes 17 KiB..8 MiB untouched, FIT at 8 MiB" % where)
    return True


def check_traced(fw, zf, tasks, v, fwup, img, d):
    """Applies every task that could reach the eMMC to the image under strace
    and fails on any write syscall below 8 MiB, whatever it writes."""
    where = os.path.basename(fw)
    loose = os.path.join(d, "loose.fw")
    without_requirements(zf, loose)
    limit = (LOADER_LAST + 1) * SECTOR - 1
    before, ran = len(v), []
    for tname, t in tasks.items():
        actions = [a for _, _, a, _ in task_calls(t)]
        if tname in SEGMENT0_TASKS or "error" in actions or not set(actions) - NO_WRITE:
            continue
        r, writes = write_trace.run(img, [fwup, "-a", "-q", "-d", img, "-t", tname, "-i", loose])
        if r.returncode:
            v.add(where, "traced task %s failed on the scratch image: %s" % (tname, r.stderr.strip()[:200]))
        elif not writes:
            v.add(where, "traced task %s: strace saw no write to the image, so the trace proves nothing" % tname)
        for s, e, what in write_trace.overlapping(writes, 0, limit):
            v.add(where, "traced task %s: %s of bytes %d..%d (LBA %d-%d), below 8 MiB"
                  % (tname, what, s, e - 1, s // SECTOR, (e - 1) // SECTOR))
        ran.append(tname)
    if len(v) == before:
        print("check-loader-area: %s traced %s: no write syscall below 8 MiB"
              % (where, " ".join(ran) or "no tasks"))


def main(argv):
    static_only = False
    if argv and argv[0] == "--static-only":
        static_only, argv = True, argv[1:]
    if not argv:
        print("usage: check-loader-area.sh [--static-only] <fw>...", file=sys.stderr)
        return 2
    fwup = os.environ.get("FWUP", "fwup")
    v = Violations()
    loaded = []
    for fw in argv:
        try:
            zf = zipfile.ZipFile(fw)
            loaded.append((fw, zf, check_static(fw, zf, v)))
        except (OSError, KeyError, zipfile.BadZipFile) as e:
            v.add(fw, "cannot read as a .fw: %s" % e)
    if not static_only:
        trace = write_trace.have_strace()
        if not trace:
            print("check-loader-area: SKIPPED the write-syscall trace: strace not found "
                  "(the static model and the byte compare still ran)", file=sys.stderr)
        with tempfile.TemporaryDirectory(prefix="loader-area-") as d:
            img = os.path.join(d, "disk.img")
            base = None
            # The first .fw with complete lays down the image every traced
            # task (ops archives included) starts from.
            for fw, zf, tasks in loaded:
                if "complete" in tasks and check_complete(fw, zf, v, fwup, img):
                    base = os.path.join(d, "base.img")
                    subprocess.run(["cp", "--sparse=always", img, base], check=True)
                    break
            for fw, zf, tasks in loaded:
                if base is None:
                    print("check-loader-area: %s: no complete task to build a disk image from, static check only"
                          % os.path.basename(fw))
                elif trace:
                    subprocess.run(["cp", "--sparse=always", base, img], check=True)
                    check_traced(fw, zf, tasks, v, fwup, img, d)
    if v:
        for line in v:
            print("check-loader-area: FAIL %s" % line, file=sys.stderr)
        return 1
    print("check-loader-area: OK (%d file%s)" % (len(argv), "" if len(argv) == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
