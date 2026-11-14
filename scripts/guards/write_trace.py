"""Runs a command under strace and reports every write syscall that reaches a
target file, as byte ranges, whatever the bytes are.

Content comparisons cannot see a rewrite with identical bytes (fwup's 128 KiB
read-modify-write of its cache segments), so this looks at the syscalls.
Reads advance the shared file position too, so they are traced for that.
Fail-closed: a write whose offset cannot be worked out, a truncate, an
O_TRUNC/O_APPEND open or a shared writable mmap of the target is reported as
covering the whole file.

Usage: write_trace.py [--record FILE] <target> <first-byte> <last-byte> -- <command...>
Without --record: exit 0 if the command succeeded and no write overlapped
[first, last], printing one line per write seen. With --record: the
command's output passes through, its exit status is returned, and FILE gets
"write <start> <end> <syscall>" per write and "overlap ..." per offender.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

WHOLE = (0, 1 << 62)

LINE = re.compile(r"^(\d+)\s+(.*)$")
CALL = re.compile(r"^([a-z0-9_]+)\((.*)$")
RESUMED = re.compile(r"^<\.\.\. ([a-z0-9_]+) resumed>(.*)$")
RET = re.compile(r"\)\s+=\s+(-?\d+|0x[0-9a-f]+)")
FD = re.compile(r"^(\d+)<(.*?)>")
# mmap(addr, len, prot, flags, fd<path>, off)
MMAP = re.compile(r"^[^,]*,[^,]*,\s*([^,]*),\s*([^,]*),\s*-?\d+(?:<(.*?)>)?\s*,")
# copy_file_range/splice(fd_in, off_in, fd_out<path>, off_out, len, flags)
COPY_DST = re.compile(r"^\d+(?:<.*?>)?\s*,\s*[^,]+,\s*\d+<(.*?)>\s*,")
# Source descriptor and the first character of its offset argument: "N" for
# NULL (the source's file position is used and advanced), "[" for a pointer.
COPY_SRC = re.compile(r"^(\d+)<(.*?)>\s*,\s*(\S)")
SENDFILE_SRC = re.compile(r"^[^,]*,\s*(\d+)<(.*?)>\s*,\s*(\S)")
# preadv2(fd, iov, iovcnt, offset, flags)
PREADV2_OFF = re.compile(r",\s*(-?\d+),\s*[^,]*\)\s+=")

# Calls whose result moves the shared file position of their descriptor.
POSITIONAL = ("write", "writev", "read", "readv", "preadv2")


def have_strace():
    return shutil.which("strace") is not None


RWF_APPEND = 0x10


def appends(rest):
    """Whether a pwritev2's flags argument (the last one) contains RWF_APPEND.
    Flags strace cannot name come out as numbers; those are checked by bit."""
    m = re.search(r",\s*([A-Za-z0-9_|x]+)\)\s+=", rest)
    if not m:
        return True
    for tok in m.group(1).split("|"):
        if tok == "RWF_APPEND":
            return True
        if tok[:1].isdigit():
            try:
                if int(tok, 0) & RWF_APPEND:
                    return True
            except ValueError:
                return True
    return False


class Desc:
    def __init__(self, path, pos=0):
        self.path = path
        self.pos = pos


class Tracker:
    def __init__(self, target):
        self.target = target
        self.tables = {}   # pid -> {fd: Desc}; threads share one table
        self.pending = {}  # pid -> (call, args)
        self.issued = {}   # pid -> (Desc, position when the pending call started)
        self.writes = []   # (start, end_exclusive, what)
        # Once the target is mapped shared without PROT_WRITE, any later
        # writable mprotect might be upgrading that mapping; mprotect has no
        # descriptor to tell, and ld.so calls it constantly, so it is ignored
        # until such a mapping exists.
        self.ro_shared = False

    def table(self, pid):
        return self.tables.setdefault(pid, {})

    def hit(self, start, end, what):
        self.writes.append((start, end, what))

    def feed(self, raw):
        m = LINE.match(raw)
        if not m:
            return
        pid, rest = int(m.group(1)), m.group(2)
        r = RESUMED.match(rest)
        if r:
            if pid not in self.pending:
                return
            call, args = self.pending.pop(pid)
            snap = self.issued.pop(pid, None)
            if snap and snap[0].pos != snap[1]:
                # Something moved the shared position while the call was in
                # flight, so where it landed is unknown.
                snap[0].pos = None
            self.handle(pid, call, args + r.group(2))
            return
        c = CALL.match(rest)
        if not c:
            return
        call, args = c.group(1), c.group(2)
        if args.endswith("<unfinished ...>"):
            body = args[: -len("<unfinished ...>")]
            self.pending[pid] = (call, body)
            if call in POSITIONAL:
                fd, _ = self.fdarg(body)
                desc = self.table(pid).get(fd)
                if desc is not None:
                    self.issued[pid] = (desc, desc.pos)
            return
        self.handle(pid, call, args)

    def finish(self):
        # The resumed line of a call that killed its process never comes; its
        # outcome is unknown, so a call that names the target counts as a write.
        for call, args in self.pending.values():
            if self.target in args:
                self.hit(*WHOLE, "%s unfinished" % call)
        self.pending.clear()
        self.issued.clear()

    def ret(self, args):
        m = RET.search(args)
        if not m:
            return None
        return int(m.group(1), 0)

    def fdarg(self, args):
        m = FD.match(args)
        if not m:
            return None, None
        return int(m.group(1)), m.group(2)

    def source_moved(self, tab, args, pattern):
        """A source read through a NULL offset advances that descriptor's
        position by an amount not worth parsing out, so the position is dropped.
        An unparseable call that names the target drops every target position."""
        m = pattern.match(args)
        if m:
            if m.group(2) == self.target and m.group(3) != "[":
                desc = tab.get(int(m.group(1)))
                if desc is not None and desc.path == self.target:
                    desc.pos = None
                else:
                    tab[int(m.group(1))] = Desc(m.group(2), None)
        elif self.target in args:
            for desc in tab.values():
                if desc is not None and desc.path == self.target:
                    desc.pos = None

    def handle(self, pid, call, args):
        tab = self.table(pid)
        rv = self.ret(args)

        if call in ("clone", "clone3", "fork", "vfork"):
            if rv is not None and rv > 0:
                if "CLONE_FILES" in args:
                    self.tables[rv] = tab
                else:
                    self.tables[rv] = dict(tab)
            return

        if call in ("open", "openat", "creat", "openat2"):
            if rv is None or rv < 0:
                return
            m = re.search(r"\)\s+=\s+\d+<(.*?)>", args)
            path = m.group(1) if m else None
            tab[rv] = Desc(path)
            if path == self.target and ("O_TRUNC" in args or "O_APPEND" in args or call == "creat"):
                self.hit(*WHOLE, "%s with O_TRUNC/O_APPEND" % call)
            return

        if call in ("dup", "dup2", "dup3") or (call == "fcntl" and "F_DUPFD" in args):
            fd, _ = self.fdarg(args)
            if fd is not None and rv is not None and rv >= 0:
                tab[rv] = tab.get(fd)
            return

        if call == "close":
            fd, _ = self.fdarg(args)
            tab.pop(fd, None)
            return

        # Their writes never show up as write syscalls, and a submission
        # carries no descriptor name to attribute it by.
        if call in ("io_uring_setup", "io_uring_enter", "io_setup", "io_submit"):
            if rv is None or rv >= 0:
                self.hit(*WHOLE, "%s: asynchronous I/O cannot be attributed" % call)
            return

        if call == "mprotect":
            if self.ro_shared and "PROT_WRITE" in args and (rv is None or rv >= 0):
                self.hit(*WHOLE, "mprotect PROT_WRITE after a read-only shared mmap")
            return

        # The descriptor that gets written is not the first argument here, so
        # these cannot go through the generic path below. A failed call wrote
        # nothing; an unknown result (rv None) is treated as a success.
        if call in ("mmap", "copy_file_range", "splice"):
            if rv is not None and rv < 0:
                return
            if call != "mmap":
                self.source_moved(tab, args, COPY_SRC)
            if call == "mmap":
                m = MMAP.match(args)
                if m:
                    if m.group(3) == self.target and "MAP_SHARED" in m.group(2):
                        if "PROT_WRITE" in m.group(1):
                            self.hit(*WHOLE, "shared writable mmap")
                        else:
                            self.ro_shared = True
                    return
            else:
                m = COPY_DST.match(args)
                if m:
                    if m.group(1) == self.target:
                        self.hit(*WHOLE, call)
                    return
            if self.target in args:
                self.hit(*WHOLE, "%s not parsed" % call)
                self.ro_shared = True
            return

        if call == "sendfile" and (rv is None or rv >= 0):
            self.source_moved(tab, args, SENDFILE_SRC)

        fd, path = self.fdarg(args)
        if fd is None:
            if call in ("truncate",) and self.target in args:
                self.hit(*WHOLE, "truncate")
            return
        desc = tab.get(fd)
        if desc is None or desc.path != path:
            desc = Desc(path, None)
            tab[fd] = desc

        if call == "lseek":
            if rv is not None and rv >= 0:
                desc.pos = rv
            return

        if path != self.target:
            return

        rest = args[FD.match(args).end():]

        # Switching an open descriptor to O_APPEND moves every later write to
        # EOF, wherever the tracked position says.
        if call == "fcntl":
            if "F_SETFL" in args and "O_APPEND" in args and (rv is None or rv >= 0):
                self.hit(*WHOLE, "fcntl F_SETFL O_APPEND")
                desc.pos = None
            return

        if call in ("read", "readv", "preadv2"):
            if rv is not None and rv < 0:
                return
            if call == "preadv2":
                m = PREADV2_OFF.search(rest)
                if not m:
                    desc.pos = None
                    return
                if m.group(1) != "-1":
                    return  # explicit offset: the position stays put
            if rv is None:
                desc.pos = None
            elif desc.pos is not None:
                desc.pos += rv
            return

        if call in ("write", "pwrite64"):
            # The requested count is only an upper bound: a short write moves
            # the position, and lands, by what the call returned.
            if rv is not None and rv < 0:
                return
            m = re.match(r',\s*""(?:\.\.\.)?,\s*(\d+)(?:,\s*(\d+))?', rest)
            if not m or (call == "pwrite64") != (m.group(2) is not None):
                self.hit(*WHOLE, "%s not parsed" % call)
                desc.pos = None
                return
            if rv is None:
                self.hit(*WHOLE, "%s result unknown" % call)
                desc.pos = None
                return
            if call == "pwrite64":
                if rv:
                    off = int(m.group(2))
                    self.hit(off, off + rv, call)
            elif desc.pos is None:
                self.hit(*WHOLE, "write at an unknown offset")
            else:
                if rv:
                    self.hit(desc.pos, desc.pos + rv, call)
                desc.pos += rv
            return

        if call in ("writev", "pwritev", "pwritev2"):
            # -s 0 elides the iovec, so the length is what the call returned.
            if rv is not None and rv < 0:
                return
            tail = re.search(r"\],\s*\d+(?:,\s*(\d+))?", rest)
            if rv is None or not tail or (call != "writev") != (tail.group(1) is not None):
                self.hit(*WHOLE, "%s not parsed" % call)
                desc.pos = None
            elif call == "pwritev2" and appends(rest):
                # RWF_APPEND writes at EOF whatever the offset argument says.
                self.hit(*WHOLE, "pwritev2 RWF_APPEND")
                desc.pos = None
            elif call != "writev":
                off = int(tail.group(1))
                self.hit(off, off + rv, call)
            elif desc.pos is None:
                self.hit(*WHOLE, "writev at an unknown offset")
            else:
                self.hit(desc.pos, desc.pos + rv, call)
                desc.pos += rv
            return

        if call == "ioctl":
            if re.search(r"BLK(SEC)?DISCARD|BLKZEROOUT|MMC_IOC", rest):
                self.hit(*WHOLE, "ioctl " + rest.split(",")[1].strip())
            return

        # sendfile's destination is its first argument; the 64-bit ABIs only
        # have the name sendfile.
        if call in ("ftruncate", "fallocate", "sendfile"):
            # Rare enough on a disk being installed that parsing offsets is
            # not worth it.
            self.hit(*WHOLE, call)


def run(target, cmd, env=None, capture=True):
    """Returns (CompletedProcess, [(start, end_exclusive, syscall), ...])."""
    target = os.path.realpath(target)
    with tempfile.TemporaryDirectory(prefix="write-trace-") as d:
        log = os.path.join(d, "trace")
        argv = ["strace", "-f", "-qq", "-y", "-s", "0", "--seccomp-bpf", "-o", log,
                "-e", "trace=open,openat,openat2,creat,close,dup,dup2,dup3,fcntl,lseek,"
                "read,readv,preadv2,write,pwrite64,writev,pwritev,pwritev2,"
                "ftruncate,truncate,fallocate,copy_file_range,sendfile,splice,ioctl,mmap,mprotect,io_uring_setup,io_uring_enter,"
                "io_setup,io_submit,clone,clone3,fork,vfork"]
        r = subprocess.run(argv + ["--"] + cmd, env=env, capture_output=capture, text=True)
        t = Tracker(target)
        with open(log, errors="replace") as f:
            for line in f:
                t.feed(line.rstrip("\n"))
        t.finish()
        return r, t.writes


def overlapping(writes, first, last):
    return [w for w in writes if w[0] <= last and w[1] - 1 >= first]


def main(argv):
    record = None
    if argv[:1] == ["--record"] and len(argv) > 1:
        record, argv = argv[1], argv[2:]
    if len(argv) < 5 or argv[3] != "--":
        print("usage: write_trace.py [--record FILE] <target> <first-byte> <last-byte> -- <command...>",
              file=sys.stderr)
        return 2
    if not have_strace():
        print("write_trace: strace not found", file=sys.stderr)
        return 2
    target, first, last, cmd = argv[0], int(argv[1], 0), int(argv[2], 0), argv[4:]
    r, writes = run(target, cmd, capture=record is None)
    bad = overlapping(writes, first, last)
    if record is not None:
        with open(record, "w") as f:
            for s, e, what in writes:
                f.write("write %d %d %s\n" % (s, e - 1, what))
            for s, e, what in bad:
                f.write("overlap %d %d %s\n" % (s, e - 1, what))
        return r.returncode
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    for s, e, what in writes:
        print("write %d..%d %s" % (s, e - 1, what))
    for s, e, what in bad:
        print("write_trace: FAIL %s to %s bytes %d..%d overlaps %d..%d"
              % (what, target, s, e - 1, first, last), file=sys.stderr)
    if r.returncode:
        return r.returncode
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
