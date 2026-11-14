#!/bin/sh
#
# Tests green-install-emmc against regular files standing in for the block
# devices, sysfs and fwup. Each case sources the tool in a fresh shell (the
# same shell running this file) and reassigns its path variables, so nothing
# here can touch a real disk. With strace and python3 present, every case
# also runs under a write-syscall trace of the fake eMMC.
#
# Usage: scripts/test-green-install-emmc.sh [--tool PATH | --break-test]
#   --tool PATH    test another copy of the tool
#   --break-test   remove each check from a scratch copy in turn and require
#                  the suite to notice

DIR=$(cd "$(dirname "$0")" && pwd)
TOOL=$DIR/../rootfs_overlay/usr/sbin/green-install-emmc
MODE=run
while [ $# -gt 0 ]; do
    case $1 in
        --tool) TOOL=$2; shift 2 ;;
        --break-test) MODE=breaktest; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done

# The tool runs under busybox ash on the board, so cases run under whichever
# shell runs this file, busybox included.
RUNSH="sh"
exe=$(readlink /proc/$$/exe 2>/dev/null) && case $exe in
    */busybox*) RUNSH="$exe sh" ;;
    ?*) RUNSH=$exe ;;
esac

ROOT=$(mktemp -d) || exit 2
ROOT=$(cd -P "$ROOT" && pwd)
trap 'rm -rf "$ROOT"' EXIT

if [ "$MODE" = breaktest ]; then
    # name|sed expression that disables one check
    # shellcheck disable=SC2016
    CASES='
check_sd_booted|s/^check_sd_booted() {/&\n    return 0/
check_emmc_present|s/^check_emmc_present() {/&\n    return 0/
check_emmc_nonremovable|s/^check_emmc_nonremovable() {/&\n    return 0/
check_emmc_is_mmc|s/^check_emmc_is_mmc() {/&\n    return 0/
check_emmc_not_boot_disk|s/^check_emmc_not_boot_disk() {/&\n    return 0/
check_emmc_512|s/^check_emmc_512() {/&\n    return 0/
check_emmc_size_minimum|s/\[ "\$EMMC_SECTORS" -ge "\$MIN_EMMC_SECTORS" \]/true/
check_emmc_size_readable|s/sysfs_value "\$EMMC_SYSFS\/size" || return 1/sysfs_value "$EMMC_SYSFS\/size"/
check_loader_present|s/^check_loader_present() {/&\n    return 0/
check_fw_platform|s/^check_fw_platform() {/&\n    return 0/
check_emmc_unused|s/^check_emmc_unused() {/&\n    return 0/
unused_emmc_numbers|s/^emmc_numbers() {/&\n    return 0/
unused_disk_number|s/add_emmc_number "\$EMMC_SYSFS\/dev" || return 1/true/
unused_partition_numbers|s/for f in "\$EMMC_SYSFS"\/\*\/dev; do/for f in; do/
unused_number_readable|s/sysfs_value "\$1" \&\& is_devnum "\$SYSFS_VALUE" || return 1/sysfs_value "$1" || return 0/
unused_number_format|s/sysfs_value "\$1" \&\& is_devnum "\$SYSFS_VALUE" || return 1/sysfs_value "$1" || return 1/
mountinfo_check|s/^check_not_mounted() {/&\n    return 0/
mountinfo_readable|s/\[ -r "\$MOUNTINFO" \] || { UNUSED_WHY="cannot read \$MOUNTINFO"; return 1; }/true/
mountinfo_parse|s/is_devnum "\${3:-}" || { UNUSED_WHY="cannot parse a line of \$MOUNTINFO"; return 1; }/true/
mountinfo_match|s/\*" \$3 "\*) UNUSED_WHY=/*" \$3 "x*) UNUSED_WHY=/
mountinfo_nonempty|s/\[ "\$mi_lines" -gt 0 \] || {.*$/true/
mountinfo_last_line|s/while IFS= read -r mi_line || \[ -n "\$mi_line" \]; do/while IFS= read -r mi_line; do/
swap_check|s/^check_not_swapped() {/&\n    return 0/
swaps_readable|s/\[ -r "\$SWAPS" \] || { UNUSED_WHY="cannot read \$SWAPS"; return 1; }/true/
swap_identify|s/node_numbers "\${1:-}" || { UNUSED_WHY="cannot identify swap device .*$/node_numbers "${1:-}" || continue/
swap_match|s/\*" \$NODE_NUMS "\*) UNUSED_WHY=/*" $NODE_NUMS "x*) UNUSED_WHY=/
swap_hex_conversion|s/NODE_NUMS=\$((0x\${hex%%:\*})):\$((0x\${hex#\*:}))/NODE_NUMS=${hex}/
holders_check|s/^check_no_holders() {/&\n    return 0/
holders_disk|s/for h in "\$EMMC_SYSFS"\/holders\/\* "\$EMMC_SYSFS"\/\*\/holders\/\*; do/for h in "$EMMC_SYSFS"\/*\/holders\/*; do/
holders_partitions|s/for h in "\$EMMC_SYSFS"\/holders\/\* "\$EMMC_SYSFS"\/\*\/holders\/\*; do/for h in "$EMMC_SYSFS"\/holders\/*; do/
check_sd_has_fit|s/^check_sd_has_fit() {/&\n    return 0/
check_gpt_rendered|s/^check_gpt_rendered() {/&\n    return 0/
check_gpt_on_emmc|s/^check_gpt_on_emmc() {/&\n    return 0/
gpt_render_status|s/"\$FWUP" -a -q -d "\$GPT_IMG" -t emmc-gpt -i "\$FW" ||/"$FWUP" -a -q -d "$GPT_IMG" -t emmc-gpt -i "$FW" || true ||/
gpt_backup_copy|s/! copy_sectors "\$BACK_LBA" "\$GPT_BACK_COUNT" || //
gpt_copy_records|s/grep -q "^\$2+0 records out" "\$TMPD\/dd.err"/true/
fw_file_exists|s/\[ -f "\$FW" \] ||/true ||/
usage_check|s/\[ \$# -eq 1 \] ||/true ||/
short_read_guard|s/grep -q "^\$n+0 records in" "\$TMPD\/dd.err" \&\& //
loader_after_compare|s/\[ "\$loader_before" = "\$loader_after" \]/true/
fit_compare|s/\[ "\$fit_sd" = "\$fit_emmc" \]/true/
fwup_exit_status|s/\[ "\$fwup_rc" -ne 0 \]/false/
'
    rc=0
    printf '%s\n' "$CASES" | while IFS='|' read -r name expr; do
        [ -n "$name" ] || continue
        copy=$ROOT/broken-$name
        sed "$expr" "$TOOL" > "$copy"
        if cmp -s "$TOOL" "$copy"; then
            echo "BREAK $name: sed did not change the tool"
            exit 3
        fi
        # shellcheck disable=SC2086
        if out=$($RUNSH "$0" --tool "$copy" 2>&1); then
            echo "BREAK $name: NOT DETECTED (suite still passes)"
            exit 3
        fi
        echo "BREAK $name: detected by $(echo "$out" | sed -n 's/^FAILED: //p' | tr '\n' ' ')"
    done || rc=$?
    exit $rc
fi

# Not `command -v`: the board's busybox ash has no `command`.
find_cmd() {
    for d in $(echo "$PATH" | tr : ' '); do
        [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
    done
    return 1
}
DD_REAL=$(find_cmd dd) || { echo "no dd in PATH" >&2; exit 2; }
STAT_REAL=$(find_cmd stat) || { echo "no stat in PATH" >&2; exit 2; }

TRACE=
if find_cmd strace >/dev/null && find_cmd python3 >/dev/null; then
    TRACE=$DIR/guards/write_trace.py
    echo "write-syscall trace: on ($RUNSH)"
else
    echo "write-syscall trace: SKIPPED: no strace or python3 ($RUNSH)"
fi

MB=1048576
# Odd sizes, so the backup GPT lands mid-segment as on a real eMMC.
EMMC_SECTORS=$((20 * 2048 + 7))
FAILS=
NCASE=0

{ printf '\320\015\376\355'; dd if=/dev/urandom bs=1024 count=64 2>/dev/null; } > "$ROOT/fit.bin"
dd if=/dev/zero of="$ROOT/window.bin" bs=$MB count=8 2>/dev/null
dd if="$ROOT/fit.bin" of="$ROOT/window.bin" conv=notrunc 2>/dev/null
cp "$ROOT/window.bin" "$ROOT/window.bad"
printf 'X' | dd of="$ROOT/window.bad" bs=1 seek=4194304 conv=notrunc 2>/dev/null

dd if=/dev/urandom of="$ROOT/sd.master" bs=$MB count=20 2>/dev/null
dd if="$ROOT/window.bin" of="$ROOT/sd.master" bs=$MB seek=8 conv=notrunc 2>/dev/null
dd if=/dev/urandom of="$ROOT/emmc.master" bs=512 count=$EMMC_SECTORS 2>/dev/null
printf 'RKNS' | dd of="$ROOT/emmc.master" bs=1 seek=32768 conv=notrunc 2>/dev/null
# The byte the loader_changed stub overwrites must differ from what it writes.
printf '\000' | dd of="$ROOT/emmc.master" bs=1 seek=51200 conv=notrunc 2>/dev/null

# Stands in for fwup; behaviour comes from files in its directory. The GPT
# it renders is fake but has the header fields the tool checks.
cat > "$ROOT/fwup.stub" <<'EOF'
#!/bin/sh
D=$(dirname "$0")
echo "$*" >> "$D/fwup.calls"
le() {
    v=$1 n=$2 fmt=
    while [ "$n" -gt 0 ]; do
        fmt="$fmt\\$(printf %03o $((v & 255)))"; v=$((v >> 8)); n=$((n - 1))
    done
    # shellcheck disable=SC2059
    printf "$fmt"
}
zeros() { dd if=/dev/zero bs=1 count="$1" 2>/dev/null; }
# header <own> <other> <entries> <count>
header() {
    printf 'EFI PART'; zeros 16; le "$1" 8; le "$2" 8; zeros 32; le "$3" 8
    le "$4" 4; le 128 4; zeros 424
}
case $1 in
    -m) printf 'meta-platform=%s\n' "$(cat "$D/meta")"; exit 0 ;;
    -a) ;;
    *) exit 98 ;;
esac
case "$*" in
    "-a -q -d $D/green-install-emmc."*"/gpt.img -t emmc-gpt -i $D/test.fw")
        img=$4
        n=$(($(stat -c %s "$img") / 512)); last=$((n - 1)); cnt=128
        case $(cat "$D/gpt_mode") in
            fail) exit 1 ;;
            entries_past_lba33) cnt=256 ;;
            backup_misplaced) last=$((n - 2)) ;;
        esac
        dd if=/dev/urandom of="$D/entries" bs=512 count=32 2>/dev/null
        { dd if=/dev/urandom bs=512 count=1 2>/dev/null; header 1 "$last" 2 "$cnt"; cat "$D/entries"; } > "$D/rendered.front"
        { cat "$D/entries"; header "$last" 1 $((last - 32)) "$cnt"; } > "$D/rendered.back"
        [ "$(cat "$D/gpt_mode")" = no_signature ] && printf 'EFI PARX' | dd of="$D/rendered.front" bs=1 seek=512 conv=notrunc 2>/dev/null
        dd if="$D/rendered.front" of="$img" conv=notrunc 2>/dev/null
        dd if="$D/rendered.back" of="$img" bs=512 seek=$((last - 32)) conv=notrunc 2>/dev/null
        # fwup grows a regular file past its size when it writes the last segment.
        dd if=/dev/zero of="$img" bs=512 seek=$((n + 100)) count=1 conv=notrunc 2>/dev/null
        exit 0 ;;
    "-a -d $D/emmc.img -t install -i $D/test.fw") ;;
    *) exit 99 ;;
esac
dev=$3
case $(cat "$D/mode") in
    ok) dd if="$D/window.bin" of="$dev" bs=512 seek=16384 conv=notrunc 2>/dev/null ;;
    fit_wrong) dd if="$D/window.bad" of="$dev" bs=512 seek=16384 conv=notrunc 2>/dev/null ;;
    no_fit) ;;
    loader_changed)
        dd if="$D/window.bin" of="$dev" bs=512 seek=16384 conv=notrunc 2>/dev/null
        printf 'X' | dd of="$dev" bs=1 seek=51200 conv=notrunc 2>/dev/null ;;
    gpt_clobbered)
        dd if="$D/window.bin" of="$dev" bs=512 seek=16384 conv=notrunc 2>/dev/null
        printf 'X' | dd of="$dev" bs=1 seek=600 conv=notrunc 2>/dev/null ;;
    fwup_fail)
        dd if="$D/window.bin" of="$dev" bs=512 seek=16384 conv=notrunc 2>/dev/null
        exit 1 ;;
esac
exit 0
EOF

# Builds a case directory in which every precondition holds.
new_case() {
    NCASE=$((NCASE + 1))
    C=$ROOT/case$NCASE
    mkdir -p "$C/sys/device" "$C/sys/queue" "$C/sys/mmcblk0p1" "$C/sys/mmcblk0p5" "$C/sys/mmcblk0p5/holders"
    echo 179:0 > "$C/sys/dev"
    echo 179:1 > "$C/sys/mmcblk0p1/dev"
    echo 179:5 > "$C/sys/mmcblk0p5/dev"
    cp "$ROOT/sd.master" "$C/sd.img"
    cp "$ROOT/emmc.master" "$C/emmc.img"
    cp "$ROOT/emmc.master" "$C/emmc.orig"
    cp "$ROOT/window.bin" "$ROOT/window.bad" "$C/"
    cp "$ROOT/fwup.stub" "$C/fwup"
    chmod +x "$C/fwup"
    ln -s "$C/sd.img" "$C/rootdisk0"
    SD_PATH=$C/sd.img
    echo 0 > "$C/sys/removable"
    echo MMC > "$C/sys/device/type"
    echo 512 > "$C/sys/queue/logical_block_size"
    echo "$EMMC_SECTORS" > "$C/sys/size"
    echo '"ha_green"' > "$C/meta"
    echo ok > "$C/mode"
    echo ok > "$C/gpt_mode"
    : > "$C/test.fw"
    : > "$C/fwup.calls"
    : > "$C/driver.extra"
    # The SD card's partition and a tmpfs; the eMMC is 179:0 with 179:1 and 179:5.
    printf '%s\n' "22 1 179:37 / /root rw,relatime - ext4 $C/sd.imgp5 rw" \
        "23 22 0:21 / /tmp rw,nosuid - tmpfs tmpfs rw" > "$C/mountinfo"
    printf 'Filename Type Size Used Priority\n' > "$C/swaps"
    : > "$C/nodes"
    LOADER_MAY_CHANGE=0
}

run_tool() {
    cat > "$C/run.sh" <<EOF
. "$TOOL"
ROOTDISK=$C/rootdisk0
SD_DISK=$SD_PATH
EMMC_DISK=$C/emmc.img
EMMC_SYSFS=$C/sys
MOUNTINFO=$C/mountinfo
SWAPS=$C/swaps
TMPBASE=$C
FWUP=$C/fwup
MIN_EMMC_SECTORS=40000
# Test files are not block devices.
is_blockdev() { [ -f "\$1" ]; }
# Files have no device numbers; \$C/nodes maps files, followed through
# symlinks, to the hex major:minor stat would print for a device node.
stat() {
    if [ "\$1 \$2 \$3" = "-L -c %t:%T" ]; then
        while read -r nf nh; do
            [ "\$4" -ef "\$nf" ] && { echo "\$nh"; return 0; }
        done < "$C/nodes"
    fi
    "$STAT_REAL" "\$@"
}
. "$C/driver.extra"
main "\$@"
EOF
    if [ -n "$TRACE" ]; then
        # shellcheck disable=SC2086
        python3 -I "$TRACE" --record "$C/writes" "$C/emmc.img" 17408 8388607 -- \
            $RUNSH "$C/run.sh" "$@" > "$C/out" 2> "$C/err"
    else
        # shellcheck disable=SC2086
        $RUNSH "$C/run.sh" "$@" > "$C/out" 2> "$C/err"
    fi
    RC=$?
}

# sectors_eq <file> <lba> <file> <lba> <count>; busybox cmp takes no offsets.
sectors_eq() {
    dd if="$1" bs=512 skip="$2" count="$5" of="$C/range.a" 2>/dev/null &&
        dd if="$3" bs=512 skip="$4" count="$5" of="$C/range.b" 2>/dev/null &&
        [ "$(wc -c < "$C/range.a")" -eq $(($5 * 512)) ] &&
        cmp -s "$C/range.a" "$C/range.b"
}

fail() {
    echo "  not ok: $1"
    FAILED_NOW=1
}

begin() {
    CASE_NAME=$1
    FAILED_NOW=0
    new_case
}

# Checked after every case: LBA 34-16383 of the fake eMMC never changes, by
# content and, when traced, by write syscall.
finish() {
    if [ -e "$C/emmc.img" ] && [ "$LOADER_MAY_CHANGE" -eq 0 ]; then
        if [ "$(wc -c < "$C/emmc.orig")" -ge 8388608 ]; then
            sectors_eq "$C/emmc.img" 34 "$C/emmc.orig" 34 $((16384 - 34))
        else
            cmp -s "$C/emmc.img" "$C/emmc.orig"
        fi || fail "eMMC bytes 17408..8388607 changed"
        if [ -n "$TRACE" ] && grep -q '^overlap' "$C/writes"; then
            fail "write syscall to eMMC bytes 17408..8388607: $(grep '^overlap' "$C/writes" | head -n 1)"
        fi
    fi
    if [ "$FAILED_NOW" -eq 1 ]; then
        FAILS="$FAILS $CASE_NAME"
        echo "FAIL $CASE_NAME"
        sed 's/^/    out: /' "$C/out"
        sed 's/^/    err: /' "$C/err"
    else
        echo "ok   $CASE_NAME"
    fi
}

assert_emmc_untouched() {
    if [ -e "$C/emmc.img" ]; then
        cmp -s "$C/emmc.img" "$C/emmc.orig" || fail "eMMC file changed"
    fi
    if [ -n "$TRACE" ] && grep -q '^write' "$C/writes"; then
        fail "write syscall to the eMMC: $(grep '^write' "$C/writes" | head -n 1)"
    fi
}

assert_install_not_run() {
    if grep -q -- '-t install' "$C/fwup.calls"; then fail "fwup install was invoked"; fi
}

# The eMMC's GPT sectors are exactly what the stub rendered.
assert_gpt_written() {
    sectors_eq "$C/emmc.img" 0 "$C/rendered.front" 0 34 || fail "eMMC LBA 0-33 is not the rendered GPT"
    sectors_eq "$C/emmc.img" $((EMMC_SECTORS - 33)) "$C/rendered.back" 0 33 ||
        fail "eMMC LBA $((EMMC_SECTORS - 33))-$((EMMC_SECTORS - 1)) is not the rendered backup GPT"
    if [ -n "$TRACE" ] && ! grep -q '^write 0 ' "$C/writes"; then
        fail "the trace saw no write of LBA 0, so it proves nothing"
    fi
}

# expect_refusal <stderr text> [tool args...]; default arg is the fw
expect_refusal() {
    want=$1; shift
    [ $# -gt 0 ] || set -- "$C/test.fw"
    run_tool "$@"
    [ "$RC" -eq 1 ] || fail "exit status $RC, want 1"
    [ "$(wc -l < "$C/err")" -eq 1 ] || fail "stderr is not exactly one line"
    grep -q "REFUSED: .*$want" "$C/err" || fail "stderr lacks '$want'"
    grep -q 'nothing was written' "$C/err" || fail "stderr does not say nothing was written"
    ! grep -q PASS "$C/out" || fail "printed PASS"
    assert_emmc_untouched
    assert_install_not_run
}

# expect_fail <stderr text> [installs]: the tool wrote, then a check failed
expect_fail() {
    run_tool "$C/test.fw"
    [ "$RC" -eq 1 ] || fail "exit status $RC, want 1"
    [ "$(tail -n 1 "$C/out" | cut -c1-5)" = "FAIL:" ] || fail "last stdout line is not FAIL"
    grep -q "$1" "$C/err" || fail "stderr lacks '$1'"
    ! grep -q '^PASS' "$C/out" || fail "printed PASS"
    [ "$(grep -c -- '-t install' "$C/fwup.calls")" -eq "${2:-1}" ] || fail "fwup install not run ${2:-1} time(s)"
}

expect_pass() {
    run_tool "$C/test.fw"
    [ "$RC" -eq 0 ] || fail "exit status $RC"
    [ "$(tail -n 1 "$C/out")" = PASS ] || fail "last line is not PASS"
    [ ! -s "$C/err" ] || fail "unexpected stderr"
    assert_gpt_written
    sectors_eq "$C/emmc.img" 16384 "$C/sd.img" 16384 16384 ||
        fail "FIT window differs from SD"
}

begin happy_path
expect_pass
[ "$(grep -c '[0-9a-f]\{64\}' "$C/out")" -eq 4 ] || fail "expected four sha256 lines"
grep -q "^eMMC: $EMMC_SECTORS sectors; GPT at LBA 0-33 and $((EMMC_SECTORS - 33))-$((EMMC_SECTORS - 1))$" "$C/out" ||
    fail "no eMMC size/GPT line"
grep -qx 'eMMC GPT: written and read back identical' "$C/out" || fail "no GPT read-back line"
grep -qx 'eMMC GPT: unchanged by the install' "$C/out" || fail "no post-install GPT line"
[ "$(grep -c -- '-t emmc-gpt' "$C/fwup.calls")" -eq 1 ] || fail "GPT not rendered exactly once"
grep -qx -- "-a -d $C/emmc.img -t install -i $C/test.fw" "$C/fwup.calls" || fail "fwup install command line"
[ "$(grep -n -- '-t emmc-gpt' "$C/fwup.calls" | cut -d: -f1)" -lt "$(grep -n -- '-t install' "$C/fwup.calls" | cut -d: -f1)" ] ||
    fail "GPT not rendered before the install"
sectors_eq "$C/emmc.img" 64 "$C/emmc.orig" 64 16320 || fail "loader area differs"
# Everything between the FIT window and the backup GPT is the stub's
# business, and the stub writes none of it.
sectors_eq "$C/emmc.img" 32768 "$C/emmc.orig" 32768 $((EMMC_SECTORS - 33 - 32768)) ||
    fail "eMMC changed between LBA 32768 and the backup GPT"
set -- "$C"/green-install-emmc.*
[ ! -e "$1" ] || fail "scratch directory left behind"
finish

begin other_odd_size
EMMC_SECTORS_SAVED=$EMMC_SECTORS
EMMC_SECTORS=$((EMMC_SECTORS + 2 * 2048 + 250))
dd if=/dev/urandom of="$C/emmc.img" bs=512 seek=$EMMC_SECTORS_SAVED count=$((EMMC_SECTORS - EMMC_SECTORS_SAVED)) conv=notrunc 2>/dev/null
cp "$C/emmc.img" "$C/emmc.orig"
echo "$EMMC_SECTORS" > "$C/sys/size"
expect_pass
finish
EMMC_SECTORS=$EMMC_SECTORS_SAVED

begin happy_path_unquoted_meta
echo ha_green > "$C/meta"
expect_pass
finish

begin no_arguments
run_tool
[ "$RC" -eq 2 ] || fail "exit status $RC, want 2"
grep -q usage "$C/err" || fail "no usage line"
assert_emmc_untouched; assert_install_not_run
finish

begin fw_file_missing
rm -f "$C/test.fw"
expect_refusal "not found"
finish

begin not_sd_booted
rm "$C/rootdisk0"; ln -s "$C/emmc.img" "$C/rootdisk0"
expect_refusal "not running from the SD card"
finish

begin rootdisk_missing
rm "$C/rootdisk0"
expect_refusal "not running from the SD card"
finish

begin rootdisk_is_other_file
rm "$C/rootdisk0"; cp "$C/sd.img" "$C/rootdisk0"
expect_refusal "not running from the SD card"
finish

begin emmc_missing
rm "$C/emmc.img" "$C/emmc.orig"
expect_refusal "not a block device"
finish

begin emmc_removable
echo 1 > "$C/sys/removable"
expect_refusal "non-removable"
finish

begin emmc_removable_unreadable
rm "$C/sys/removable"
expect_refusal "non-removable"
finish

begin emmc_not_mmc
echo SD > "$C/sys/device/type"
expect_refusal "not an MMC"
finish

begin emmc_is_boot_disk
# Only reachable when SD_DISK and EMMC_DISK alias the same device.
rm "$C/rootdisk0"; ln -s "$C/emmc.img" "$C/rootdisk0"
SD_PATH=$C/emmc.img
run_tool "$C/test.fw"
[ "$RC" -eq 1 ] || fail "exit status $RC, want 1"
grep -q 'REFUSED: .*is the boot disk' "$C/err" || fail "stderr lacks 'is the boot disk'"
assert_emmc_untouched; assert_install_not_run
finish

begin emmc_4k_sectors
echo 4096 > "$C/sys/queue/logical_block_size"
expect_refusal "512-byte logical blocks"
finish

begin emmc_sector_size_unreadable
rm "$C/sys/queue/logical_block_size"
expect_refusal "512-byte logical blocks"
finish

begin emmc_too_small
echo 39999 > "$C/sys/size"
expect_refusal "below 40000 sectors"
finish

begin emmc_size_unreadable
rm "$C/sys/size"
# Low enough that a stale value from an earlier sysfs read would pass.
echo MIN_EMMC_SECTORS=100 > "$C/driver.extra"
expect_refusal "size is unreadable"
finish

begin emmc_size_garbage
echo 41000x > "$C/sys/size"
expect_refusal "size is unreadable"
finish

begin loader_absent
dd if=/dev/zero of="$C/emmc.img" bs=1 seek=32768 count=4 conv=notrunc 2>/dev/null
cp "$C/emmc.img" "$C/emmc.orig"
expect_refusal "no RKNS stock loader"
finish

begin loader_wrong_magic
printf 'RKNX' | dd of="$C/emmc.img" bs=1 seek=32768 conv=notrunc 2>/dev/null
cp "$C/emmc.img" "$C/emmc.orig"
expect_refusal "no RKNS stock loader"
finish

begin wrong_platform
echo '"some_other_board"' > "$C/meta"
expect_refusal "not a ha_green firmware"
finish

begin platform_missing_in_meta
: > "$C/meta"
expect_refusal "not a ha_green firmware"
finish

# A refusal from the in-use check must come before anything is rendered or
# written, not just before the install.
expect_unused_refusal() {
    expect_refusal "$1"
    ! grep -q -- '^-a' "$C/fwup.calls" || fail "fwup was applied"
}

# emmc_node <name> <hex major:minor>: a file standing in for a device node.
emmc_node() {
    : > "$C/$1"
    echo "$C/$1 $2" >> "$C/nodes"
}

begin emmc_partition_mounted
echo "41 22 179:1 / /mnt rw - vfat $C/emmc.imgp1 rw" >> "$C/mountinfo"
expect_unused_refusal "mounted (device 179:1 in"
finish

begin emmc_partition_mounted_under_another_name
echo "41 22 179:5 / /mnt rw - ext4 /dev/disk/by-id/mmc-X-part5 rw" >> "$C/mountinfo"
expect_unused_refusal "mounted (device 179:5 in"
finish

begin emmc_partition_bind_mounted
echo "41 22 179:5 /sub /mnt rw - ext4 /dev/root rw" >> "$C/mountinfo"
expect_unused_refusal "mounted (device 179:5 in"
finish

begin emmc_whole_disk_mounted
echo "41 22 179:0 / /mnt rw - ext4 /dev/whatever rw" >> "$C/mountinfo"
expect_unused_refusal "mounted (device 179:0 in"
finish

begin emmc_mounted_last_line_without_newline
printf '41 22 179:5 / /mnt rw - ext4 x rw' >> "$C/mountinfo"
expect_unused_refusal "mounted (device 179:5 in"
finish

begin mountinfo_unreadable
rm "$C/mountinfo"
expect_unused_refusal "cannot read"
finish

begin mountinfo_empty
: > "$C/mountinfo"
expect_unused_refusal "is empty"
finish

begin mountinfo_line_unparseable
echo "garbage line here - x y" >> "$C/mountinfo"
expect_unused_refusal "cannot parse a line"
finish

begin mountinfo_short_line
echo "41 22" >> "$C/mountinfo"
expect_unused_refusal "cannot parse a line"
finish

begin emmc_disk_number_unreadable
rm "$C/sys/dev"
expect_unused_refusal "cannot read the device numbers"
finish

begin emmc_partition_number_unreadable
echo 179 > "$C/sys/mmcblk0p5/dev"
expect_unused_refusal "cannot read the device numbers"
finish

begin emmc_partition_number_empty
: > "$C/sys/mmcblk0p1/dev"
expect_unused_refusal "cannot read the device numbers"
finish

begin emmc_used_as_swap
emmc_node mmcblk0p5 b3:5
echo "$C/mmcblk0p5 partition 1024 0 -2" >> "$C/swaps"
expect_unused_refusal "used as swap ($C/mmcblk0p5)"
finish

begin emmc_used_as_swap_through_an_alias
emmc_node node.p5 b3:5
ln -s "$C/node.p5" "$C/by-id-swap"
echo "$C/by-id-swap partition 1024 0 -2" >> "$C/swaps"
expect_unused_refusal "used as swap ($C/by-id-swap)"
finish

begin emmc_disk_used_as_swap
emmc_node node.disk b3:0
echo "$C/node.disk partition 1024 0 -2" >> "$C/swaps"
expect_unused_refusal "used as swap"
finish

begin swap_device_unidentifiable
echo "$C/does-not-exist partition 1024 0 -2" >> "$C/swaps"
expect_unused_refusal "cannot identify swap device"
finish

begin swaps_unreadable
rm "$C/swaps"
expect_unused_refusal "cannot read"
finish

begin emmc_partition_held_by_a_mapper
: > "$C/sys/mmcblk0p5/holders/dm-0"
expect_unused_refusal "held by dm-0"
finish

begin emmc_disk_held_by_a_mapper
mkdir "$C/sys/holders"; : > "$C/sys/holders/md0"
expect_unused_refusal "held by md0"
finish

begin unrelated_mounts_and_swap_do_not_refuse
# Anonymous 0:N devices (btrfs, overlay), other disks, a swap on another disk
# and a swap file.
printf '%s\n' "41 22 0:44 / /data rw - btrfs /dev/x rw" "42 22 179:33 / /boot rw - vfat /dev/y rw" \
    "43 22 8:1 / /mnt rw - ext4 /dev/sda1 rw" >> "$C/mountinfo"
emmc_node node.sd b3:21
emmc_node swapfile 0:0
printf '%s\n' "$C/node.sd partition 1024 0 -2" "$C/swapfile file 1024 0 -3" >> "$C/swaps"
expect_pass
finish

begin sd_has_no_fit
dd if=/dev/zero of="$C/sd.img" bs=512 seek=16384 count=8 conv=notrunc 2>/dev/null
expect_refusal "no FIT"
finish

begin emmc_loader_unreadable
# Long enough for the RKNS check, too short for the whole loader area; the
# sysfs size is the device's own, so that check still passes.
dd if="$C/emmc.orig" of="$C/emmc.img" bs=1 count=33000 2>/dev/null
cp "$C/emmc.img" "$C/emmc.orig"
expect_refusal "cannot read the loader area"
finish

begin gpt_render_fails
echo fail > "$C/gpt_mode"
expect_refusal "could not render the eMMC GPT"
finish

begin gpt_entries_past_lba33
echo entries_past_lba33 > "$C/gpt_mode"
expect_refusal "rendered GPT does not lie in LBA 0-33 and $((EMMC_SECTORS - 33))-$((EMMC_SECTORS - 1))"
finish

begin gpt_backup_misplaced
echo backup_misplaced > "$C/gpt_mode"
expect_refusal "rendered GPT does not lie in"
finish

begin gpt_no_signature
echo no_signature > "$C/gpt_mode"
expect_refusal "rendered GPT does not lie in"
finish

begin gpt_write_fails
# shellcheck disable=SC2016
printf 'dd() { case "$*" in *"of=%s"*) return 1 ;; esac; "%s" "$@"; }\n' "$C/emmc.img" "$DD_REAL" > "$C/driver.extra"
expect_fail "writing the GPT" 0
grep -q "^eMMC loader area .* after:" "$C/out" || fail "no after-hash when the GPT write failed"
finish

begin gpt_write_short
# dd stops after one sector yet exits 0; the record count must catch it.
cat > "$C/driver.extra" <<EOF
dd() {
    case "\$*" in
        *"of=$C/emmc.img"*)
            for a in "\$@"; do
                shift
                case \$a in count=*) set -- "\$@" count=1 ;; *) set -- "\$@" "\$a" ;; esac
            done
            "$DD_REAL" "\$@"
            return 0 ;;
    esac
    "$DD_REAL" "\$@"
}
EOF
expect_fail "writing the GPT" 0
finish

begin gpt_write_lost
# dd reports every record written but the eMMC keeps its old sectors.
cat > "$C/driver.extra" <<EOF
dd() {
    case "\$*" in
        *"of=$C/emmc.img"*)
            for a in "\$@"; do case \$a in count=*) echo "\${a#count=}+0 records out" >&2 ;; esac; done
            return 0 ;;
    esac
    "$DD_REAL" "\$@"
}
EOF
expect_fail "GPT read back from .* differs" 0
finish

begin gpt_clobbered_by_install
echo gpt_clobbered > "$C/mode"
expect_fail "GPT changed during the install"
finish

begin loader_area_changed_by_fwup
echo loader_changed > "$C/mode"
LOADER_MAY_CHANGE=1
expect_fail "loader area changed"
finish

begin fit_not_written
echo no_fit > "$C/mode"
expect_fail "FIT differs"
finish

begin fit_differs
echo fit_wrong > "$C/mode"
expect_fail "FIT differs"
finish

begin fwup_exits_nonzero
echo fwup_fail > "$C/mode"
expect_fail "fwup exited"
finish

if [ -n "$FAILS" ]; then
    echo "FAILED: $FAILS" | sed 's/  */ /g'
    exit 1
fi
echo "all $NCASE cases passed"
