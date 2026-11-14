"""Checks write_trace.py's parser against strace lines. Prints "<ok|FAIL|SKIP>\\t<case>\\t<detail>"
per case for test-guards.sh to tabulate; exits 1 on any FAIL.

The synthetic lines cover shapes fwup and the kernel tools never produce
(mmap, copy_file_range and splice onto the target), so the real-strace cases
below pin those shapes to what strace prints rather than what we assumed.
"""

import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import write_trace as wt  # noqa: E402

T = "/img/target.img"
TGT, OTH, SRC = "3<%s>" % T, "3</img/other.img>", "4</img/src.bin>"
WHOLE = wt.WHOLE
CASES = []


def case(fn):
    CASES.append(fn)
    return fn


def trace(*lines):
    t = wt.Tracker(T)
    for line in lines:
        t.feed(line)
    t.finish()
    return t.writes


def whole(writes):
    return [w for w in writes if w[:2] == WHOLE]


def expect_hit(writes, what=None):
    if not whole(writes) or (what and not any(what in w[2] for w in whole(writes))):
        return "no whole-file hit%s: %r" % (" for " + what if what else "", writes)


def expect_none(writes):
    if writes:
        return "unexpected writes: %r" % (writes,)


def mmap(fd, prot, flags, ret="0x7f3a5c000000"):
    return "100 mmap(NULL, 8192, %s, %s, %s, 0) = %s" % (prot, flags, fd, ret)


@case
def mmap_shared_writable_target():
    return expect_hit(trace(mmap(TGT, "PROT_READ|PROT_WRITE", "MAP_SHARED")), "shared writable mmap")


@case
def mmap_shared_validate_writable_target():
    return expect_hit(trace(mmap(TGT, "PROT_WRITE", "MAP_SHARED_VALIDATE|MAP_FIXED")))


@case
def mmap_private_writable_target():
    return expect_none(trace(mmap(TGT, "PROT_READ|PROT_WRITE", "MAP_PRIVATE")))


@case
def mmap_shared_readonly_target():
    return expect_none(trace(mmap(TGT, "PROT_READ", "MAP_SHARED")))


@case
def mmap_shared_writable_other_file():
    return expect_none(trace(mmap(OTH, "PROT_WRITE", "MAP_SHARED")))


@case
def mmap_anonymous():
    return expect_none(trace(mmap("-1", "PROT_READ|PROT_WRITE", "MAP_SHARED|MAP_ANONYMOUS")))


@case
def mmap_failed():
    return expect_none(trace(mmap(TGT, "PROT_WRITE", "MAP_SHARED", "-1 EACCES (Permission denied)")))


@case
def mmap_unparseable_mentions_target():
    return expect_hit(trace("100 mmap(NULL ??? %s ???) = 0x7f3a5c000000" % TGT), "not parsed")


@case
def mmap_unfinished_resumed():
    return expect_hit(trace(
        "100 mmap(NULL, 8192, PROT_WRITE, MAP_SHARED, %s, 0 <unfinished ...>" % TGT,
        "101 write(1</dev/null>, \"\"..., 1) = 1",
        "100 <... mmap resumed>) = 0x7f3a5c000000"))


def copy(call, src, dst, ret="4096", offs=("NULL", "NULL")):
    return "100 %s(%s, %s, %s, %s, 4096, 0) = %s" % (call, src, offs[0], dst, offs[1], ret)


for _call in ("copy_file_range", "splice"):
    def _mk(call):
        pipe = "5<pipe:[30435979]>"

        def dst_target():
            return expect_hit(trace(copy(call, SRC, TGT, offs=("[0]", "[4096]"))), call)

        def dst_target_null_offsets():
            return expect_hit(trace(copy(call, pipe, TGT)), call)

        def src_target_only():
            return expect_none(trace(copy(call, TGT, "4</img/out.bin>", offs=("[0]", "NULL"))))

        def dst_other():
            return expect_none(trace(copy(call, SRC, OTH)))

        def failed():
            return expect_none(trace(copy(call, SRC, TGT, ret="-1 EBADF (Bad file descriptor)")))

        def unparseable_mentions_target():
            return expect_hit(trace("100 %s(%s, %s) = 1" % (call, SRC, TGT)), "not parsed")

        def unparseable_source_only_is_still_flagged():
            # Fail closed: the target name is somewhere in the arguments.
            return expect_hit(trace("100 %s(%s ???) = 1" % (call, TGT)), "not parsed")

        def unfinished_resumed():
            return expect_hit(trace(
                "100 %s(%s, NULL, %s, NULL, 4096, 0 <unfinished ...>" % (call, SRC, TGT),
                "101 write(1</dev/null>, \"\"..., 1) = 1",
                "100 <... %s resumed>) = 4096" % call), call)

        def unfinished_resumed_failed():
            return expect_none(trace(
                "100 %s(%s, NULL, %s, NULL, 4096, 0 <unfinished ...>" % (call, SRC, TGT),
                "100 <... %s resumed>) = -1 EINVAL (Invalid argument)" % call))

        for fn in (dst_target, dst_target_null_offsets, src_target_only, dst_other, failed,
                   unparseable_mentions_target, unparseable_source_only_is_still_flagged,
                   unfinished_resumed, unfinished_resumed_failed):
            fn.__name__ = "%s_%s" % (call, fn.__name__)
            CASES.append(fn)
    _mk(_call)


@case
def sendfile_target_is_destination():
    return expect_hit(trace("100 sendfile(%s, %s, [0] => [10], 10) = 10" % (TGT, SRC)), "sendfile")


@case
def sendfile_target_is_source_only():
    return expect_none(trace("100 sendfile(5<socket:[1]>, %s, [0] => [10], 10) = 10" % TGT))


OPEN = "100 openat(AT_FDCWD, \"%s\", O_RDWR) = %s" % (T, TGT)


@case
def pwrite64_still_ranged():
    got = trace(OPEN, "100 pwrite64(%s, \"\"..., 512, 4096) = 512" % TGT)
    if got != [(4096, 4608, "pwrite64")]:
        return "got %r" % (got,)


@case
def write_after_lseek_still_ranged():
    got = trace(OPEN, "100 lseek(%s, 1024, SEEK_SET) = 1024" % TGT, "100 write(%s, \"\"..., 100) = 100" % TGT)
    if got != [(1024, 1124, "write")]:
        return "got %r" % (got,)


@case
def writev_length_is_the_return_value():
    got = trace(OPEN, "100 lseek(%s, 1024, SEEK_SET) = 1024" % TGT,
                "100 writev(%s, [...], 2) = 5" % TGT, "100 writev(%s, [...], 1) = 3" % TGT)
    if got != [(1024, 1029, "writev"), (1029, 1032, "writev")]:
        return "got %r" % (got,)


@case
def writev_failed_writes_nothing_and_keeps_position():
    got = trace(OPEN, "100 writev(%s, [...], 2) = -1 ENOSPC (No space left on device)" % TGT,
                "100 write(%s, \"\"..., 10) = 10" % TGT)
    if got != [(0, 10, "write")]:
        return "got %r" % (got,)


@case
def writev_unfinished_has_no_length():
    return expect_hit(trace(OPEN, "100 writev(%s, [...], 2 <unfinished ...>" % TGT))


@case
def pwritev_range_from_return():
    got = trace(OPEN, "100 pwritev(%s, [...], 1, 8192) = 3" % TGT,
                "100 pwritev2(%s, [...], 1, 4096, 0) = 7" % TGT)
    if got != [(8192, 8195, "pwritev"), (4096, 4103, "pwritev2")]:
        return "got %r" % (got,)


@case
def pwritev2_at_current_position_is_whole_file():
    return expect_hit(trace(OPEN, "100 pwritev2(%s, [...], 1, -1, 0) = 3" % TGT))


@case
def write_advances_by_the_return_value():
    got = trace(OPEN, "100 write(%s, \"\"..., 100) = 60" % TGT, "100 write(%s, \"\"..., 10) = 10" % TGT)
    if got != [(0, 60, "write"), (60, 70, "write")]:
        return "got %r" % (got,)


@case
def write_failed_records_nothing_and_keeps_position():
    got = trace(OPEN, "100 write(%s, \"\"..., 100) = -1 ENOSPC (No space left on device)" % TGT,
                "100 write(%s, \"\"..., 10) = 10" % TGT)
    if got != [(0, 10, "write")]:
        return "got %r" % (got,)


@case
def write_zero_return_records_nothing():
    got = trace(OPEN, "100 write(%s, \"\"..., 100) = 0" % TGT, "100 write(%s, \"\"..., 10) = 10" % TGT)
    if got != [(0, 10, "write")]:
        return "got %r" % (got,)


@case
def write_unfinished_resumed_uses_the_return_value():
    got = trace(OPEN, "100 write(%s, \"\"..., 100 <unfinished ...>" % TGT, "101 write(1</dev/null>, \"\"..., 1) = 1",
                "100 <... write resumed>) = 60", "100 write(%s, \"\"..., 10) = 10" % TGT)
    if got != [(0, 60, "write"), (60, 70, "write")]:
        return "got %r" % (got,)


@case
def write_unfinished_never_resumed_is_whole_file():
    return expect_hit(trace(OPEN, "100 write(%s, \"\"..., 100 <unfinished ...>" % TGT), "unfinished")


@case
def write_unfinished_with_a_seek_meanwhile_is_whole_file():
    return expect_hit(trace(OPEN, "100 clone(child_stack=NULL, flags=CLONE_VM|CLONE_FILES) = 101",
                            "100 write(%s, \"\"..., 100 <unfinished ...>" % TGT,
                            "101 lseek(%s, 4096, SEEK_SET) = 4096" % TGT,
                            "100 <... write resumed>) = 100"), "unknown offset")


@case
def write_result_unknown_loses_the_position():
    got = trace(OPEN, "100 write(%s, \"\"..., 100) = ?" % TGT, "100 write(%s, \"\"..., 10) = 10" % TGT)
    if [w[2] for w in whole(got)] != ["write result unknown", "write at an unknown offset"]:
        return "got %r" % (got,)


@case
def pwrite64_short_write_uses_the_return_value():
    got = trace(OPEN, "100 pwrite64(%s, \"\"..., 512, 4096) = 100" % TGT)
    if got != [(4096, 4196, "pwrite64")]:
        return "got %r" % (got,)


@case
def pwrite64_failed_records_nothing():
    return expect_none(trace(OPEN, "100 pwrite64(%s, \"\"..., 512, 4096) = -1 EIO (Input/output error)" % TGT))


@case
def pwrite64_unfinished_resumed_uses_the_return_value():
    got = trace(OPEN, "100 pwrite64(%s, \"\"..., 512, 4096 <unfinished ...>" % TGT,
                "100 <... pwrite64 resumed>) = 100")
    if got != [(4096, 4196, "pwrite64")]:
        return "got %r" % (got,)


@case
def fcntl_setfl_append_is_whole_file():
    return expect_hit(trace(OPEN, "100 fcntl(%s, F_SETFL, O_RDWR|O_APPEND|O_LARGEFILE) = 0" % TGT), "O_APPEND")


@case
def fcntl_setfl_without_append_is_ignored():
    return expect_none(trace(OPEN, "100 fcntl(%s, F_SETFL, O_RDWR|O_NONBLOCK) = 0" % TGT,
                             "100 fcntl(%s, F_GETFL) = 0x8002 (flags O_RDWR|O_LARGEFILE)" % TGT))


@case
def fcntl_setfl_append_failed_is_ignored():
    return expect_none(trace(OPEN, "100 fcntl(%s, F_SETFL, O_RDWR|O_APPEND) = -1 EPERM (Operation not permitted)" % TGT))


@case
def fcntl_setfl_append_on_other_file_is_ignored():
    return expect_none(trace("100 fcntl(%s, F_SETFL, O_RDWR|O_APPEND) = 0" % OTH))


def pwritev2(flags, off="4096", ret="3"):
    return "100 pwritev2(%s, [...], 1, %s, %s) = %s" % (TGT, off, flags, ret)


@case
def pwritev2_rwf_append_is_whole_file():
    return expect_hit(trace(OPEN, pwritev2("RWF_APPEND")), "RWF_APPEND")


@case
def pwritev2_rwf_append_among_other_flags():
    return expect_hit(trace(OPEN, pwritev2("RWF_DSYNC|RWF_APPEND")), "RWF_APPEND")


@case
def pwritev2_numeric_flags_with_the_append_bit():
    return expect_hit(trace(OPEN, pwritev2("0x10")), "RWF_APPEND") or \
        expect_hit(trace(OPEN, pwritev2("RWF_DSYNC|0x10")), "RWF_APPEND")


@case
def pwritev2_flags_that_do_not_move_the_data_stay_ranged():
    got = trace(OPEN, pwritev2("RWF_DSYNC|RWF_SYNC|RWF_HIPRI|RWF_NOWAIT"), pwritev2("0x2"))
    if got != [(4096, 4099, "pwritev2")] * 2:
        return "got %r" % (got,)


@case
def pwritev2_rwf_append_failed_records_nothing():
    return expect_none(trace(OPEN, pwritev2("RWF_APPEND", ret="-1 EOPNOTSUPP (Operation not supported)")))


@case
def pwritev2_rwf_append_on_other_file_is_ignored():
    return expect_none(trace("100 pwritev2(%s, [...], 1, 0, RWF_APPEND) = 3" % OTH))


def got_ranges(*lines):
    got = trace(*lines)
    return None if got == [(4096, 4097, "write")] else "got %r" % (got,)


W1 = "100 write(%s, \"\"..., 1) = 1" % TGT


@case
def read_advances_the_position():
    return got_ranges(OPEN, "100 read(%s, \"\"..., 4096) = 4096" % TGT, W1)


@case
def short_read_advances_by_the_return_value():
    return got_ranges(OPEN, "100 read(%s, \"\"..., 8192) = 4096" % TGT, W1)


@case
def failed_read_keeps_the_position():
    got = trace(OPEN, "100 read(%s, 0x7ffd1000, 4096) = -1 EIO (Input/output error)" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def read_at_eof_keeps_the_position():
    return got_ranges(OPEN, "100 read(%s, \"\"..., 4096) = 4096" % TGT,
                      "100 read(%s, \"\"..., 4096) = 0" % TGT, W1)


@case
def read_unfinished_resumed_uses_the_return_value():
    return got_ranges(OPEN, "100 read(%s, \"\"..., 8192 <unfinished ...>" % TGT,
                      "101 write(1</dev/null>, \"\"..., 1) = 1",
                      "100 <... read resumed>) = 4096", W1)


@case
def read_unfinished_with_a_seek_meanwhile_is_whole_file():
    return expect_hit(trace(OPEN, "100 clone(child_stack=NULL, flags=CLONE_VM|CLONE_FILES) = 101",
                            "100 read(%s, \"\"..., 100 <unfinished ...>" % TGT,
                            "101 lseek(%s, 4096, SEEK_SET) = 4096" % TGT,
                            "100 <... read resumed>) = 100", W1), "unknown offset")


@case
def read_result_unknown_makes_the_next_write_whole_file():
    return expect_hit(trace(OPEN, "100 read(%s, \"\"..., 4096) = ?" % TGT, W1), "unknown offset")


@case
def read_after_lseek():
    return got_ranges(OPEN, "100 lseek(%s, 1000, SEEK_SET) = 1000" % TGT,
                      "100 read(%s, \"\"..., 3096) = 3096" % TGT, W1)


@case
def read_on_a_dup_advances_the_shared_position():
    return got_ranges(OPEN, "100 dup(%s) = 5<%s>" % (TGT, T), "100 read(5<%s>, \"\"..., 4096) = 4096" % T, W1)


@case
def read_in_a_forked_child_advances_the_shared_position():
    return got_ranges(OPEN, "100 clone(child_stack=NULL, flags=SIGCHLD) = 101",
                      "101 read(%s, \"\"..., 4096) = 4096" % TGT, W1)


@case
def read_on_another_file_is_ignored():
    got = trace(OPEN, "100 read(%s, \"\"..., 4096) = 4096" % SRC, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def readv_advances_the_position():
    return got_ranges(OPEN, "100 readv(%s, [{iov_base=\"\"..., iov_len=4096}], 1) = 4096" % TGT, W1)


@case
def readv_failed_keeps_the_position():
    got = trace(OPEN, "100 readv(%s, 0x7ffd1000, 1) = -1 EIO (Input/output error)" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def pread64_does_not_move_the_position():
    got = trace(OPEN, "100 pread64(%s, \"\"..., 4096, 100) = 4096" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def preadv_does_not_move_the_position():
    got = trace(OPEN, "100 preadv(%s, [{iov_base=\"\"..., iov_len=4096}], 1, 100) = 4096" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


def preadv2(off, ret="4096"):
    return "100 preadv2(%s, [{iov_base=\"\"..., iov_len=4096}], 1, %s, 0) = %s" % (TGT, off, ret)


@case
def preadv2_at_current_position_advances():
    return got_ranges(OPEN, preadv2("-1"), W1)


@case
def preadv2_with_an_offset_does_not_move_the_position():
    got = trace(OPEN, preadv2("100"), W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def preadv2_unparseable_loses_the_position():
    return expect_hit(trace(OPEN, "100 preadv2(%s, ???) = 4096" % TGT, W1), "unknown offset")


@case
def sendfile_from_target_with_null_offset_loses_the_position():
    return expect_hit(trace(OPEN, "100 sendfile(5<socket:[1]>, %s, NULL, 10) = 10" % TGT, W1), "unknown offset")


@case
def sendfile_from_target_with_an_offset_pointer_keeps_the_position():
    got = trace(OPEN, "100 sendfile(5<socket:[1]>, %s, [0] => [10], 10) = 10" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def sendfile_from_target_failed_keeps_the_position():
    got = trace(OPEN, "100 sendfile(5<socket:[1]>, %s, NULL, 10) = -1 EINVAL (Invalid argument)" % TGT, W1)
    return None if got == [(0, 1, "write")] else "got %r" % (got,)


@case
def sendfile_unparseable_mentioning_target_loses_the_position():
    return expect_hit(trace(OPEN, "100 sendfile(5<socket:[1]>, %s ???) = 10" % TGT, W1), "unknown offset")


for _call in ("copy_file_range", "splice"):
    def _mk_src(call):
        def src_target_null_offset_loses_the_position():
            return expect_hit(trace(OPEN, copy(call, TGT, "4</img/out.bin>"), W1), "unknown offset")

        def src_target_with_an_offset_keeps_the_position():
            got = trace(OPEN, copy(call, TGT, "4</img/out.bin>", offs=("[0] => [4096]", "NULL")), W1)
            return None if got == [(0, 1, "write")] else "got %r" % (got,)

        def src_target_failed_keeps_the_position():
            got = trace(OPEN, copy(call, TGT, "4</img/out.bin>", ret="-1 EBADF (Bad file descriptor)"), W1)
            return None if got == [(0, 1, "write")] else "got %r" % (got,)

        for fn in (src_target_null_offset_loses_the_position, src_target_with_an_offset_keeps_the_position,
                   src_target_failed_keeps_the_position):
            fn.__name__ = "%s_%s" % (call, fn.__name__)
            CASES.append(fn)
    _mk_src(_call)


RO_MAP = mmap(TGT, "PROT_READ", "MAP_SHARED")
MPROT = "100 mprotect(0x7f3a5c000000, 8192, %s) = %s"


@case
def mprotect_without_a_shared_mapping_is_ignored():
    return expect_none(trace(MPROT % ("PROT_READ|PROT_WRITE", "0")))


@case
def mprotect_writable_after_readonly_shared_mapping():
    return expect_hit(trace(RO_MAP, MPROT % ("PROT_READ|PROT_WRITE", "0")), "mprotect")


@case
def mprotect_readonly_after_readonly_shared_mapping():
    return expect_none(trace(RO_MAP, MPROT % ("PROT_READ", "0")))


@case
def mprotect_failed_after_readonly_shared_mapping():
    return expect_none(trace(RO_MAP, MPROT % ("PROT_WRITE", "-1 EACCES (Permission denied)")))


@case
def mprotect_after_private_or_other_file_mapping():
    return expect_none(trace(mmap(TGT, "PROT_READ", "MAP_PRIVATE"), mmap(OTH, "PROT_READ", "MAP_SHARED"),
                             MPROT % ("PROT_WRITE", "0")))


@case
def mprotect_after_failed_readonly_shared_mapping():
    return expect_none(trace(mmap(TGT, "PROT_READ", "MAP_SHARED", "-1 EACCES (Permission denied)"),
                             MPROT % ("PROT_WRITE", "0")))


for _call, _args in (("io_uring_setup", "4, {flags=0}"), ("io_uring_enter", "5<anon_inode:[io_uring]>, 1, 0, 0, NULL, 128"),
                     ("io_setup", "128, [0x7f3a5c000000]"), ("io_submit", "0x7f3a5c000000, 1, [0x55d0c0a0]")):
    def _mk_io(call, args):
        def ok():
            return expect_hit(trace("100 %s(%s) = 0" % (call, args)), "asynchronous I/O")

        def failed():
            return expect_none(trace("100 %s(%s) = -1 ENOSYS (Function not implemented)" % (call, args)))

        for fn in (ok, failed):
            fn.__name__ = "%s_%s" % (call, fn.__name__)
            CASES.append(fn)
    _mk_io(_call, _args)


@case
def unfinished_call_on_target_never_resumed():
    return expect_hit(trace("100 copy_file_range(%s, NULL, %s, NULL, 4096, 0 <unfinished ...>" % (SRC, TGT)), "unfinished")


@case
def unfinished_call_on_other_file_never_resumed():
    return expect_none(trace("100 copy_file_range(%s, NULL, %s, NULL, 4096, 0 <unfinished ...>" % (SRC, OTH)))


def real(name, code, expect):
    """Runs code (argv: target, source, other) under the module's own run()."""
    def fn():
        if not wt.have_strace():
            return "SKIP no strace"
        d = tempfile.mkdtemp(prefix="write-trace-test-")
        try:
            paths = [os.path.join(d, n) for n in ("target.img", "src.bin", "other.bin")]
            for p in paths:
                with open(p, "wb") as f:
                    f.write(b"\xa5" * 16384)
            r, writes = wt.run(paths[0], [sys.executable, "-I", "-c", code] + paths)
            if r.returncode:
                return "SKIP syscall unavailable here: " + r.stderr.strip().splitlines()[-1][:100]
            return expect(writes)
        finally:
            shutil.rmtree(d)
    fn.__name__ = name
    CASES.append(fn)


def exactly(what):
    def check(writes):
        hits = whole(writes)
        if len(hits) != 1 or what not in hits[0][2]:
            return "wanted exactly one %r hit, got %r" % (what, hits)
    return check


def none(writes):
    hits = whole(writes)
    if hits:
        return "unexpected hits: %r" % (hits,)


PRE = "import mmap, os, sys\nt, s, o = sys.argv[1:]\nfd = os.open(t, os.O_RDWR)\n"

real("strace_mmap_only_shared_writable_is_a_write", PRE + """
for flags, prot in ((mmap.MAP_PRIVATE, mmap.PROT_READ | mmap.PROT_WRITE),
                    (mmap.MAP_SHARED, mmap.PROT_READ),
                    (mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)):
    mmap.mmap(fd, 8192, flags, prot).close()
""", exactly("shared writable mmap"))

real("strace_copy_file_range_into_target", PRE + """
os.copy_file_range(os.open(s, os.O_RDONLY), fd, 4096)
""", exactly("copy_file_range"))

real("strace_copy_file_range_from_target_only", PRE + """
os.copy_file_range(fd, os.open(o, os.O_WRONLY), 4096, offset_src=0)
""", none)

real("strace_splice_into_target", PRE + """
r, w = os.pipe()
os.write(w, b"x" * 4096)
os.splice(r, fd, 4096, offset_dst=0)
""", exactly("splice"))

real("strace_splice_from_target_only", PRE + """
r, w = os.pipe()
os.splice(fd, w, 4096, offset_src=0)
""", none)


real("strace_writev_and_pwritev_ranges", PRE + """
os.lseek(fd, 1000, os.SEEK_SET)
os.writev(fd, [b"abc", b"de"])
os.pwritev(fd, [b"xyz"], 4096)
""", lambda w: None if w == [(1000, 1005, "writev"), (4096, 4099, "pwritev2")] or w == [(1000, 1005, "writev"), (4096, 4099, "pwritev")]
   else "got %r" % (w,))

real("strace_read_then_write_lands_after_the_read", PRE + """
os.read(fd, 4096)
os.write(fd, b"x")
""", lambda w: None if w == [(4096, 4097, "write")] else "got %r" % (w,))

real("strace_readv_then_write", PRE + """
os.readv(fd, [bytearray(1000), bytearray(24)])
os.write(fd, b"x")
""", lambda w: None if w == [(1024, 1025, "write")] else "got %r" % (w,))

real("strace_pread_does_not_move_the_position", PRE + """
os.pread(fd, 4096, 100)
os.write(fd, b"x")
""", lambda w: None if w == [(0, 1, "write")] else "got %r" % (w,))

real("strace_sendfile_from_target_then_write", PRE + """
os.sendfile(os.open(o, os.O_WRONLY), fd, None, 4096)
os.write(fd, b"x")
""", exactly("unknown offset"))

real("strace_sendfile_from_target_with_offset_then_write", PRE + """
os.sendfile(os.open(o, os.O_WRONLY), fd, 0, 4096)
os.write(fd, b"x")
""", lambda w: None if w == [(0, 1, "write")] else "got %r" % (w,))

real("strace_copy_file_range_from_target_then_write", PRE + """
os.copy_file_range(fd, os.open(o, os.O_WRONLY), 4096)
os.write(fd, b"x")
""", exactly("unknown offset"))

real("strace_pwritev2_rwf_append", PRE + """
if not hasattr(os, "RWF_APPEND"):
    sys.exit("os.RWF_APPEND unavailable")
os.pwritev(fd, [b"abc"], 0, os.RWF_APPEND)
""", exactly("RWF_APPEND"))

real("strace_fcntl_setfl_append", PRE + """
import fcntl
fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_APPEND)
os.write(fd, b"abc")
""", lambda w: None if any(x[:2] == WHOLE and "O_APPEND" in x[2] for x in w) else "got %r" % (w,))

real("strace_mprotect_upgrading_a_readonly_shared_mapping", PRE + """
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.mprotect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
anon = libc.mmap(None, 8192, 3, 0x22, -1, 0)
libc.mprotect(anon, 8192, 1)
libc.mprotect(anon, 8192, 3)
ro = libc.mmap(None, 8192, 1, mmap.MAP_SHARED, fd, 0)
assert libc.mprotect(ro, 8192, 3) == 0
""", exactly("mprotect"))

real("strace_io_uring_setup", PRE + """
import ctypes
libc = ctypes.CDLL(None, use_errno=True)
if libc.syscall(425, 4, ctypes.create_string_buffer(120)) < 0:
    sys.exit("io_uring_setup refused: " + os.strerror(ctypes.get_errno()))
""", exactly("io_uring_setup"))


def main():
    fails = 0
    for fn in CASES:
        try:
            err = fn()
        except Exception as e:  # noqa: BLE001 - a crash in the parser is a failure
            err = "raised %r" % (e,)
        if err and err.startswith("SKIP "):
            print("SKIP\t%s\t%s" % (fn.__name__, err[5:]))
        elif err:
            fails += 1
            print("FAIL\t%s\t%s" % (fn.__name__, err))
        else:
            print("ok\t%s\t" % fn.__name__)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
