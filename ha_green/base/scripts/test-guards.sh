#!/bin/sh
#
# Shows that every build guard fails when its invariant is broken, using only
# the repo files and fabricated inputs. A guard that never fails is worth
# nothing, and a violation the guard shrugs off is worse than none.
#
# Needs python3 and fwup; strace for the write-syscall rows, which are
# reported as SKIPPED without it. Usage: scripts/test-guards.sh

# The single-quoted mutations below are literal fwup/U-Boot variable references.
# shellcheck disable=SC2016
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
S=$REPO/scripts
CONTRACT=$REPO/uboot/stock-fit-contract.txt
T=$(mktemp -d "${TMPDIR:-/tmp}/test-guards.XXXXXX")
trap 'rm -rf "$T"' EXIT
ROWS=$T/rows
FAILS=0

command -v fwup >/dev/null || { echo "test-guards: fwup is required" >&2; exit 2; }
FWUP_REAL=$(command -v fwup)
export FWUP_REAL
HAVE_STRACE=
command -v strace >/dev/null && HAVE_STRACE=1
SKIPS=0

row() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ROWS"
}

# expect_fail <invariant> <violation> <message fragment> <command...>
expect_fail() {
    inv=$1 viol=$2 pat=$3
    shift 3
    rc=0
    out=$("$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        row "$inv" "$viol" "NOT CAUGHT (exit 0)"
        FAILS=$((FAILS + 1))
    elif echo "$out" | grep -qF -e "$pat"; then
        row "$inv" "$viol" "caught (exit $rc): $pat"
    else
        row "$inv" "$viol" "FAILED FOR THE WRONG REASON (exit $rc): $(echo "$out" | head -n 2 | tr '\n' ' ' | cut -c1-120)"
        FAILS=$((FAILS + 1))
    fi
}

# expect_traced: expect_fail for a row only the write-syscall trace can see.
expect_traced() {
    if [ -n "$HAVE_STRACE" ]; then
        expect_fail "$@"
    else
        row "$1" "$2" "SKIPPED: no strace"
        SKIPS=$((SKIPS + 1))
    fi
}

# A clean baseline per guard, so a later failure can only come from the
# mutation under test.
expect_ok() {
    inv=$1 viol=$2
    shift 2
    rc=0
    out=$("$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        row "$inv" "$viol" "passes"
    else
        row "$inv" "$viol" "BASELINE FAILED (exit $rc): $(echo "$out" | head -n 2 | tr '\n' ' ' | cut -c1-120)"
        FAILS=$((FAILS + 1))
    fi
}

# subst <file> <old> <new>: first literal occurrence; refuses a no-op so a
# stale pattern cannot make a test pass vacuously.
subst() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if old not in s:
    sys.exit("test-guards: pattern not found in %s: %s" % (p, old))
open(p, "w").write(s.replace(old, new, 1))
PY
}

# --- fixtures

python3 -I "$S"/guards/fit_fabricate.py "$CONTRACT" "$T"/good.itb || exit 2

IMG=$T/sys/images
mkdir -p "$IMG"
python3 -I - "$IMG" "$T"/good.itb <<'PY'
import struct, sys, zlib
d, itb = sys.argv[1:]
body = (b"nerves_fw_active=a\0nerves_fw_validated=1\0\0").ljust(131072 - 4, b"\0")
open(d + "/uboot-env.bin", "wb").write(struct.pack("<I", zlib.crc32(body)) + body)
open(d + "/u-boot.itb", "wb").write(open(itb, "rb").read())
open(d + "/Image", "wb").write(b"\x11" * (1 << 20))
open(d + "/rk3566-ha-green.dtb", "wb").write(b"\x22" * 65536)
open(d + "/rootfs.squashfs", "wb").write(b"\x33" * (4 << 20))
open(d + "/idbloader.img", "wb").write(b"RKNS" + b"\0" * 4092)
PY
NERVES_SYSTEM=$T/sys
NERVES_SDK_IMAGES=$IMG
NERVES_SDK_VERSION=0.0.0
NERVES_FW_VCS_IDENTIFIER="test"
NERVES_FW_MISC=""
export NERVES_SYSTEM NERVES_SDK_IMAGES NERVES_SDK_VERSION NERVES_FW_VCS_IDENTIFIER NERVES_FW_MISC

# build_fw <conf> <out.fw>, with images/fwup_include reset from the repo and
# then optionally edited by $EDIT_COMMON.
build_fw() {
    rm -rf "$IMG/fwup_include"
    cp -r "$REPO/fwup_include" "$IMG/"
    cp "$1" "$T"/fw-test.conf
    [ -z "${EDIT_COMMON:-}" ] || "$EDIT_COMMON" "$IMG/fwup_include/fwup-common.conf"
    fwup -c -f "$T"/fw-test.conf -o "$2" 2>"$T"/fwup.err || { cat "$T"/fwup.err >&2; return 1; }
}

fresh_conf() {
    cp "$REPO/fwup.conf" "$T"/conf-mut
}

# loader_case <violation> <message fragment> <mutation function> [trace fragment]
# The mutation edits $T/conf-mut, or fwup-common.conf through EDIT_COMMON.
# With a trace fragment, a second row requires the write-syscall trace to
# catch the same mutation on its own.
loader_case() {
    viol=$1 pat=$2
    fresh_conf
    EDIT_COMMON=""
    "$3"
    if build_fw "$T"/conf-mut "$T"/mut.fw; then
        expect_fail "no write to LBA 64-16383 (fwup)" "$viol" "$pat" "$S"/check-loader-area.sh "$T"/mut.fw
        [ -z "${4:-}" ] ||
            expect_traced "no write syscall below 8 MiB (fwup)" "$viol" "$4" "$S"/check-loader-area.sh "$T"/mut.fw
    else
        row "no write to LBA 64-16383 (fwup)" "$viol" "FIXTURE: fwup rejected the mutated conf: $(head -n 1 "$T"/fwup.err | cut -c1-100)"
        FAILS=$((FAILS + 1))
    fi
    EDIT_COMMON=""
}

# --- loader area

fresh_conf
build_fw "$T"/conf-mut "$T"/good.fw
fwup -c -f "$REPO"/fwup-ops.conf -o "$T"/ops.fw
expect_ok "no write to LBA 64-16383 (fwup)" "repo fwup.conf + fwup-ops.conf, static + dynamic" "$S"/check-loader-area.sh "$T"/good.fw "$T"/ops.fw
expect_ok "no write to LBA 64-16383 (fwup)" "repo fwup-ops.conf, static" "$S"/check-loader-area.sh --static-only "$T"/ops.fw
if [ -n "$HAVE_STRACE" ]; then
    out=$("$S"/check-loader-area.sh "$T"/good.fw "$T"/ops.fw 2>&1)
    for t in install.a install.b upgrade.a upgrade.b factory-reset prevent-revert.a revert.a validate.a; do
        if echo "$out" | grep -q "traced.* ${t}[ :]"; then
            row "every eMMC-capable task is traced" "$t" "traced"
        else
            row "every eMMC-capable task is traced" "$t" "NOT TRACED"
            FAILS=$((FAILS + 1))
        fi
    done
else
    row "every eMMC-capable task is traced" "all" "SKIPPED: no strace"
    SKIPS=$((SKIPS + 1))
fi

m_raw64() { subst "$T"/conf-mut 'raw_write(${ROOTFS_A_PART_OFFSET})' 'raw_write(64)'; }
m_memset() { subst "$T"/conf-mut 'raw_memset(${ROOTFS_B_PART_OFFSET}, 256, 0xff)' 'raw_memset(100, 8, 0xff)'; }
m_trim() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(100, 8)'; }
m_trim0() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(0, 256)'; }
m_trim_window() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(16384, 16384)'; }
m_trim_window_below() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(16000, 1000)'; }
m_trim_window_above() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(32000, 1000)'; }
m_trim_window_last() { subst "$T"/conf-mut 'trim(${ROOTFS_A_PART_OFFSET}, ${ROOTFS_A_PART_COUNT})' 'trim(32767, 1)'; }
m_trim_window_complete() { subst "$T"/conf-mut '        gpt_write(gpt-sd)
' '        gpt_write(gpt-sd)
        trim(16384, 16384)
'; }
m_trim0_complete() { subst "$T"/conf-mut '        gpt_write(gpt-sd)
' '        gpt_write(gpt-sd)
        trim(0, 256)
'; }
m_gpt_install() { subst "$T"/conf-mut '        info("Installing to the eMMC")
' '        info("Installing to the eMMC")
        gpt_write(gpt-emmc)
'; }
m_gpt_newtask() { printf '\ntask repartition {\n    on-init { gpt_write(gpt-sd) }\n}\n' >>"$T"/conf-mut; }
m_upgrade256() { subst "$T"/conf-mut 'delta-source-raw-count=${ROOTFS_B_PART_COUNT}
        raw_write(${ROOTFS_A_PART_OFFSET})' 'delta-source-raw-count=${ROOTFS_B_PART_COUNT}
        raw_write(256)'; }
m_unaligned() { subst "$T"/conf-mut '# Reset the validation status and boot to B next time.' 'raw_memset(16380, 8, 0)'; }
m_fat() { subst "$T"/conf-mut 'fat_write(${BOOT_PART_OFFSET}, "Image.a")' 'fat_write(100, "Image.a")'; }
ed_gptpart() { subst "$1" 'define!(ENV_PART_OFFSET, 32768)' 'define!(ENV_PART_OFFSET, 100)'; }
m_gptpart() { EDIT_COMMON=ed_gptpart; }
ed_envblock() { subst "$1" 'define!(UBOOT_ENV_OFFSET, 32768)' 'define!(UBOOT_ENV_OFFSET, 64)'; }
m_envblock() { EDIT_COMMON=ed_envblock; }
m_window() { subst "$T"/conf-mut '# Reset the validation status and boot to A next time.' 'raw_memset(${FIT_OFFSET}, 8, 0x00)'; }
m_execute() { subst "$T"/conf-mut 'info("Upgrading partition A")' 'info("Upgrading partition A") execute("true")'; }
m_idblock() {
    subst "$T"/conf-mut '# Last, so a torn full write' 'file-resource idbloader.img { host-path = "${NERVES_SYSTEM}/images/idbloader.img" }
# Last, so a torn full write'
    subst "$T"/conf-mut '    on-resource u-boot.itb {' '    on-resource idbloader.img { raw_write(40000) }
    on-resource u-boot.itb {'
}

loader_case "raw_write(64) of the rootfs" "inside the stock loader area" m_raw64
loader_case "raw_memset over LBA 100" "inside the stock loader area" m_memset
loader_case "trim over LBA 100" "trims fwup cache segment LBA 0-255" m_trim
loader_case "trim(0, 256) in upgrade.a" "trims fwup cache segment LBA 0-255" m_trim0
loader_case "trim(0, 256) in complete (SD-only)" "trims fwup cache segment LBA 0-255" m_trim0_complete
loader_case "trim(16384, 16384) over the FIT window in upgrade.a" "which overlaps the FIT window 16384-32767" m_trim_window
loader_case "trim(16000, 1000) reaching into the FIT window from below" "which overlaps the FIT window 16384-32767" m_trim_window_below
loader_case "trim(32000, 1000) starting inside the FIT window" "which overlaps the FIT window 16384-32767" m_trim_window_above
loader_case "trim(32767, 1) of the window's last sector" "which overlaps the FIT window 16384-32767" m_trim_window_last
loader_case "trim(16384, 16384) in complete (SD-only)" "which overlaps the FIT window 16384-32767" m_trim_window_complete
loader_case "gpt_write re-added to install.a" "install.a on-init gpt_write(gpt-emmc): dirties fwup cache segment LBA 0-255" m_gpt_install \
    "traced task install.a: pwrite64 of bytes 0..131071"
loader_case "new task with a gpt_write, not on the SD-only list" "task repartition on-init gpt_write(gpt-sd): dirties fwup cache segment LBA 0-255" m_gpt_newtask
loader_case "raw_write(256) of the rootfs in upgrade.a" "raw_write(256): dirties fwup cache segment LBA 256-" m_upgrade256 \
    "traced task upgrade.a: pwrite64 of bytes 131072.."
loader_case "unaligned raw_memset at LBA 16380 in upgrade.b" "dirties fwup cache segment LBA 16128-16639" m_unaligned \
    "traced task upgrade.b: pwrite64 of bytes 8257536.."
loader_case "fat_write at partition offset LBA 100" "FAT offset LBA 100" m_fat
loader_case "GPT partition starting at LBA 100" "starts at LBA 100" m_gptpart
loader_case "state block moved to LBA 64" "inside the stock loader area" m_envblock
loader_case "FIT window written by an upgrade task" "the FIT window, outside complete/install" m_window
loader_case "execute() action" "cannot be bounded" m_execute
loader_case "an idblock shipped as a resource" "Rockchip idblock" m_idblock

# Static analysis cannot see a lying fwup, so prove the byte comparison too:
# a wrapper that applies the task and then scribbles on LBA 2048.
cat >"$T"/badfwup <<'BADFWUP'
#!/bin/sh
"$FWUP_REAL" "$@" || exit $?
while [ $# -gt 0 ]; do
    [ "$1" = -d ] && img=$2
    shift
done
printf X | dd of="$img" bs=1 seek=1048576 conv=notrunc 2>/dev/null
BADFWUP
chmod +x "$T"/badfwup
expect_fail "no write to LBA 64-16383 (fwup)" "byte changed at 1 MiB after applying complete" "task complete changed byte 1048576" \
    env FWUP="$T"/badfwup "$S"/check-loader-area.sh "$T"/good.fw

# Content checks cannot see a sector rewritten with its own bytes, which is
# what fwup's segment read-modify-write does; only the trace can.
cat >"$T"/samefwup <<'SAMEFWUP'
#!/bin/sh
"$FWUP_REAL" "$@" || exit $?
case " $* " in *" -t install.a "*) ;; *) exit 0 ;; esac
while [ $# -gt 0 ]; do
    [ "$1" = -d ] && img=$2
    shift
done
dd if="$img" of="$img" bs=512 skip=100 seek=100 count=1 conv=notrunc 2>/dev/null
SAMEFWUP
chmod +x "$T"/samefwup
expect_traced "no write syscall below 8 MiB (fwup)" "install.a rewrites LBA 100 with its own bytes" "traced task install.a: write of bytes 51200..51711" \
    env FWUP="$T"/samefwup "$S"/check-loader-area.sh "$T"/good.fw

# The trace parser itself, on synthetic strace lines plus real strace output
# for the calls fwup and the kernel tools never issue (mmap, copy_file_range,
# splice onto the target).
python3 -I "$S"/guards/test_write_trace.py >"$T"/wt.out 2>&1 || true
while IFS=$(printf '\t') read -r st name detail; do
    case $st in
        ok) row "write-trace parser sees every write to the target" "$name" "passes" ;;
        SKIP)
            row "write-trace parser sees every write to the target" "$name" "SKIPPED: $detail"
            SKIPS=$((SKIPS + 1)) ;;
        *)
            row "write-trace parser sees every write to the target" "$name" "FAILED: $st $detail"
            FAILS=$((FAILS + 1)) ;;
    esac
done <"$T"/wt.out
[ -s "$T"/wt.out ] || { row "write-trace parser sees every write to the target" "test_write_trace.py" "FAILED: no output"; FAILS=$((FAILS + 1)); }

python3 -I - "$IMG/u-boot.itb" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"\xa5" * (1 << 20))
PY
fresh_conf
build_fw "$T"/conf-mut "$T"/nomagic.fw
expect_fail "FIT at 8 MiB after complete" "u-boot.itb without FDT magic" "no FIT magic at 8 MiB" "$S"/check-loader-area.sh "$T"/nomagic.fw
printf 'not a zip' >"$T"/junk.fw
expect_fail "readable .fw" "file that is not a zip" "cannot read as a .fw" "$S"/check-loader-area.sh "$T"/junk.fw

# --- destination checks: fwup cannot see which device -d names, so the SD
# card and the eMMC are told apart by what complete and install wrote.

dest_fw() {
    sed '/require-path-on-device/d' "$1" >"$T"/dest.conf
    [ -z "${2:-}" ] || sed -i "/$2/d" "$T"/dest.conf
    build_fw "$T"/dest.conf "$3"
}
dest_fw "$REPO"/fwup.conf "" "$T"/sys-loose.fw
dest_fw "$REPO"/fwup-ops.conf "" "$T"/ops-loose.fw
dest_fw "$REPO"/fwup-ops.conf 'require-fat-file-exists(${BOOT_PART_OFFSET}, "medium.sd")' "$T"/ops-nomedium.fw
rm -f "$T"/sd.img "$T"/emmc.img
truncate -s 3G "$T"/sd.img "$T"/emmc.img
fwup -a -q -d "$T"/sd.img -t complete -i "$T"/good.fw
fwup -a -q -d "$T"/emmc.img -t install -i "$T"/sys-loose.fw >/dev/null
cp --sparse=always "$T"/emmc.img "$T"/emmc.ref
I="expand-data and complete stay off the eMMC"
expect_ok "$I" "expand-data on an SD that complete wrote" fwup -a -q -d "$T"/sd.img -t expand-data -i "$T"/ops-loose.fw
expect_fail "$I" "expand-data aimed at an eMMC that install wrote" "Not expanding" \
    fwup -a -q -d "$T"/emmc.img -t expand-data -i "$T"/ops-loose.fw
expect_fail "$I" "complete aimed at an eMMC that install wrote" "is an installed eMMC" \
    fwup -a -q -d "$T"/emmc.img -t complete -i "$T"/good.fw
expect_ok "$I" "refusals left the eMMC image unchanged" cmp "$T"/emmc.img "$T"/emmc.ref
expect_ok "$I" "control: without the medium.sd check expand-data does run there" \
    fwup -a -q -d "$T"/emmc.img -t expand-data -i "$T"/ops-nomedium.fw
expect_ok "$I" "complete re-writes an SD that complete wrote" fwup -a -q -d "$T"/sd.img -t complete -i "$T"/good.fw

# --- FIT

fit() { "$S"/check-fit.sh "$@"; }
expect_ok "FIT matches the stock contract" "fabricated FIT from the contract" fit "$T"/good.itb "$CONTRACT"
fit_case() {
    python3 -I "$S"/guards/fit_fabricate.py "$CONTRACT" "$T"/bad.itb "$1"
    expect_fail "$2" "$3" "$4" fit "$T"/bad.itb "$CONTRACT"
}
fit_case gzip "every image compression = none" "u-boot image gzip-compressed" "must be \"none\""
fit_case no-compression "every image compression = none" "compression property missing" "must be \"none\""
fit_case md5 "every hash is sha256" "atf-1 hash algo md5" "must be sha256"
fit_case nohash "every image has a hash" "atf-2 without a hash node" "no hash node"
fit_case firmware "default config firmware = atf-1" "firmware = atf-2" "must be atf-1"
fit_case default-missing "default config exists" "default names a missing config" "no default configuration"
fit_case load "load/entry addresses equal stock" "u-boot load address +0x1000" "contract line missing or different"
fit_case drop-node "node set equals stock" "atf-6 node removed" "image atf-6"
fit_case oversize "FIT fits LBA 16384-32767" "9 MiB of external data" "over the 8 MiB window"
fit_case truncated "external data present" "file cut short" "truncated"
fit_case no-size "every image has a payload" "atf-1 without data-size" "image atf-1: no data-size"
fit_case zero-size "every image has a payload" "atf-1 data-size = 0" "image atf-1: data-size is 0"
fit_case no-offset "every image has a payload" "atf-1 without data-offset/data-position" "image atf-1: neither data-offset nor data-position"
fit_case no-payload "every image has a payload" "atf-1 with no data properties" "image atf-1: no data-size"
fit_case embedded "payloads are external" "atf-1 with an embedded data property" "image atf-1: embedded data"
fit_case both-offsets "one payload location per image" "atf-1 with data-offset and data-position" "image atf-1: both data-offset and data-position"
fit_case into-header "payloads clear of the FDT header" "atf-2 data-position inside the header" "image atf-2: payload starts at byte 8, inside the FDT header"
fit_case overlap "payloads do not overlap" "atf-3 placed 16 bytes after atf-2's start" "images atf-2 and atf-3: payloads overlap"
fit_case truncated "payload inside the file" "file cut short" "extends past the end of the file"
fit_case no-hash-value "payload hash matches" "atf-1 hash without value" "image atf-1: hash has no 32-byte value"
fit_case short-hash-value "payload hash matches" "atf-1 hash value of 16 bytes" "image atf-1: hash has no 32-byte value"
fit_case bad-hash "payload hash matches" "one atf-1 payload byte flipped" "image atf-1: hash value does not match"
fit_case dangling-ref "default config names existing images" "atf-6 node deleted, still in loadables" "names image atf-6, which is not under /images"
fit_case extra-image "every image is in the default config" "extra atf-7 node" "image atf-7: not referenced by default configuration"
fit_case no-env "boot script compiled in" "bootcmd without the script" "boot script is not compiled in"
printf 'not a fit, but long enough for a header check to be reached........' >"$T"/junk.itb
expect_fail "FIT parses" "garbage file" "not an FDT" fit "$T"/junk.itb "$CONTRACT"

cat >"$T"/uboot.config <<'EOF'
CONFIG_SPL_FIT_SIGNATURE=y
CONFIG_SPL_SHA256=y
# CONFIG_SPL_GZIP is not set
# CONFIG_SPL_LZMA is not set
# CONFIG_ENV_REDUNDANT is not set
# CONFIG_CMD_SF is not set
CONFIG_ENV_IS_NOWHERE=y
CONFIG_ENV_SIZE=0x20000
EOF
cfg_case() {
    cp "$T"/uboot.config "$T"/uboot.mut
    subst "$T"/uboot.mut "$2" "$3"
    expect_fail "U-Boot .config matches the stock SPL contract" "$1" "$4" fit --config "$T"/uboot.mut "$T"/good.itb "$CONTRACT"
}
expect_ok "U-Boot .config matches the stock SPL contract" "fabricated good .config" fit --config "$T"/uboot.config "$T"/good.itb "$CONTRACT"
cfg_case "SPL_FIT_SIGNATURE off" 'CONFIG_SPL_FIT_SIGNATURE=y' '# CONFIG_SPL_FIT_SIGNATURE is not set' "CONFIG_SPL_FIT_SIGNATURE must be y"
cfg_case "SPL_SHA256 off" 'CONFIG_SPL_SHA256=y' '# CONFIG_SPL_SHA256 is not set' "CONFIG_SPL_SHA256 must be y"
cfg_case "SPL_GZIP on" '# CONFIG_SPL_GZIP is not set' 'CONFIG_SPL_GZIP=y' "CONFIG_SPL_GZIP must not be set"
cfg_case "SPL_LZMA on" '# CONFIG_SPL_LZMA is not set' 'CONFIG_SPL_LZMA=y' "CONFIG_SPL_LZMA must not be set"
cfg_case "ENV_REDUNDANT on" '# CONFIG_ENV_REDUNDANT is not set' 'CONFIG_ENV_REDUNDANT=y' "CONFIG_ENV_REDUNDANT must not be set"
cfg_case "CMD_SF on" '# CONFIG_CMD_SF is not set' 'CONFIG_CMD_SF=y' "CONFIG_CMD_SF must not be set"
cfg_case "ENV_IS_NOWHERE off" 'CONFIG_ENV_IS_NOWHERE=y' '# CONFIG_ENV_IS_NOWHERE is not set' "CONFIG_ENV_IS_NOWHERE must be y"
cfg_case "ENV_SIZE 0x1f000" 'CONFIG_ENV_SIZE=0x20000' 'CONFIG_ENV_SIZE=0x1f000' "CONFIG_ENV_SIZE must be 0x20000"

# --- env/layout consistency

W=$T/repo
fresh_repo() {
    rm -rf "$W"
    mkdir -p "$W/uboot" "$W/linux"
    cp "$REPO"/uboot/uboot.env "$REPO"/uboot/green.fragment "$W/uboot/"
    cp "$REPO"/linux/nerves.config "$REPO"/linux/rk3566.config "$W/linux/"
    cp "$REPO"/fwup.conf "$REPO"/fwup-ops.conf "$REPO"/nerves_defconfig "$W/"
    cp -r "$REPO"/fwup_include "$REPO"/rootfs_overlay "$W/"
}
env_case() {
    fresh_repo
    subst "$W/$3" "$4" "$5"
    expect_fail "$1" "$2" "$6" "$S"/check-env-config.sh "$W"
}
fresh_repo
expect_ok "state block/FIT/file names agree" "repo files" "$S"/check-env-config.sh "$W"
I="state block location agrees"
env_case "$I" "fw_env.config offset 0x1000200" rootfs_overlay/etc/fw_env.config '0x1000000' '0x1000200' "state offset"
env_case "$I" "script reads LBA 0x8001" uboot/uboot.env 'mmc read ${nerves_state_addr} 0x8000 0x100' 'mmc read ${nerves_state_addr} 0x8001 0x100' "reads the state with"
env_case "$I" "script writes LBA 0x8001" uboot/uboot.env 'mmc write ${nerves_state_addr} 0x8000 0x100' 'mmc write ${nerves_state_addr} 0x8001 0x100' "writes it with"
env_case "$I" "fwup UBOOT_ENV_OFFSET 32769" fwup_include/fwup-common.conf 'define!(UBOOT_ENV_OFFSET, 32768)' 'define!(UBOOT_ENV_OFFSET, 32769)' "state LBA"
env_case "$I" "ENV_PART_OFFSET != UBOOT_ENV_OFFSET" fwup_include/fwup-common.conf 'define!(ENV_PART_OFFSET, 32768)' 'define!(ENV_PART_OFFSET, 32776)' "ENV_PART_OFFSET"
I="state block size agrees"
env_case "$I" "fwup UBOOT_ENV_COUNT 255" fwup_include/fwup-common.conf 'define!(UBOOT_ENV_COUNT, 256)' 'define!(UBOOT_ENV_COUNT, 255)' "state size"
env_case "$I" "fw_env.config size 0x1f000" rootfs_overlay/etc/fw_env.config '0x20000' '0x1f000' "fw_env.config size"
env_case "$I" "ENVIMAGE_SIZE 126976" nerves_defconfig 'ENVIMAGE_SIZE="131072"' 'ENVIMAGE_SIZE="126976"' "ENVIMAGE_SIZE"
env_case "$I" "CONFIG_ENV_SIZE 0x1f000" uboot/green.fragment 'CONFIG_ENV_SIZE=0x20000' 'CONFIG_ENV_SIZE=0x1f000' "CONFIG_ENV_SIZE"
env_case "$I" "script load import size 0x1f000" uboot/uboot.env 'env import -c ${nerves_state_addr} 0x20000' 'env import -c ${nerves_state_addr} 0x1f000' "env import"
env_case "$I" "script rebuild import size 0x1f000" uboot/uboot.env 'env import -c 0x12180000 0x20000' 'env import -c 0x12180000 0x1f000' "env import"
env_case "$I" "script save export size 0x1f000" uboot/uboot.env 'env export -c -s 0x20000 ${nerves_state_addr}' 'env export -c -s 0x1f000 ${nerves_state_addr}' "env export"
env_case "$I" "script rebuild export size 0x1f000" uboot/uboot.env 'env export -c -s 0x20000 0x12180000' 'env export -c -s 0x1f000 0x12180000' "env export"
env_case "$I" "script buffer clear size 0x1f000" uboot/uboot.env 'mw.b ${nerves_state_addr} 0 0x20000' 'mw.b ${nerves_state_addr} 0 0x1f000' "script buffer clear"
I="FIT location agrees"
env_case "$I" "script probes LBA 0x4001" uboot/uboot.env 'mmc read ${nerves_scratch_addr} 0x4000 1' 'mmc read ${nerves_scratch_addr} 0x4001 1' "FIT LBA"
env_case "$I" "FIT_OFFSET 16385 (script probe unchanged)" fwup_include/fwup-common.conf 'define!(FIT_OFFSET, 16384)' 'define!(FIT_OFFSET, 16385)' "FIT LBA"
env_case "$I" "FIT window reaching the state block" fwup_include/fwup-common.conf 'define!(FIT_COUNT, 16384)' 'define!(FIT_COUNT, 16385)' "overlaps the state block"
I="boot FAT file names agree"
env_case "$I" "script loads Kernel.<slot>" uboot/uboot.env 'Image.${nerves_slot}' 'Kernel.${nerves_slot}' "never writes it"
env_case "$I" "fwup also writes Image.c" fwup.conf 'on-resource Image { fat_write(${BOOT_PART_OFFSET}, "Image.a") }' 'on-resource Image { fat_write(${BOOT_PART_OFFSET}, "Image.a")
        fat_write(${BOOT_PART_OFFSET}, "Image.c") }' "never loads it"
env_case "$I" "script loads another dtb name" uboot/uboot.env 'rk3566-ha-green.${nerves_slot}.dtb' 'rk3566-green.${nerves_slot}.dtb' "boot script loads"
env_case "$I" "defconfig builds another dtb" nerves_defconfig 'rockchip/rk3566-ha-green' 'rockchip/rk3566-green' "builds rk3566-green.dtb"
env_case "$I" "defconfig builds another FIT name" nerves_defconfig 'FORMAT_CUSTOM_NAME="u-boot.itb"' 'FORMAT_CUSTOM_NAME="u-boot.img"' "nerves_defconfig builds"

# --- GUID lookups

guid_case() {
    fresh_repo
    subst "$W/$2" "$3" "$4"
    expect_fail "no lookup by GUID/UUID/label" "$1" "check-no-guid-lookup: FAIL" "$S"/check-no-guid-lookup.sh "$W"
}
fresh_repo
expect_ok "no lookup by GUID/UUID/label" "repo files" "$S"/check-no-guid-lookup.sh "$W"
guid_case "root=PARTUUID= on the kernel command line" uboot/uboot.env 'root=/dev/mmcblk${nerves_disk}p${nerves_part}' 'root=PARTUUID=1234-01'
guid_case "root=UUID= on the kernel command line" uboot/uboot.env 'rootwait' 'rootwait root=UUID=abcd'
guid_case "/dev/disk/by-partuuid path in erlinit.config" rootfs_overlay/etc/erlinit.config '-m /dev/rootdisk0p5:/data:ext4:nodev:' '-m /dev/disk/by-partuuid/abcd:/data:ext4:nodev:'
guid_case "U-Boot part uuid lookup in the script" uboot/uboot.env 'setenv nerves_disk 0;' 'part uuid mmc 0:3 x; setenv nerves_disk 0;'
guid_case "U-Boot gpt guid command" uboot/uboot.env 'setenv nerves_disk 0;' 'gpt guid mmc 0 x; setenv nerves_disk 0;'
guid_case "U-Boot part number lookup" uboot/uboot.env 'setenv nerves_disk 0;' 'part number mmc 0 rootfs-a x; setenv nerves_disk 0;'
guid_case "LABEL= in a fwup file" fwup.conf 'require-unmounted-destination = true' 'require-unmounted-destination = true
    info("root=LABEL=data")'
guid_case "by-partlabel in the install tool" rootfs_overlay/usr/sbin/green-install-emmc 'PLATFORM=ha_green' 'PLATFORM=ha_green
ls /dev/disk/by-partlabel/rootfs-a'

# --- kernel config

cat >"$T"/kernel.config <<'EOF'
# CONFIG_ROCKCHIP_VENDOR_STORAGE is not set
# CONFIG_ROCKCHIP_VENDOR_STORAGE_UPDATE_LOADER is not set
# CONFIG_SPI_ROCKCHIP_SFC is not set
# CONFIG_MTD_SPI_NOR is not set
# CONFIG_FIQ_DEBUGGER is not set
# CONFIG_DEVMEM is not set
# CONFIG_MMC_TEST is not set
CONFIG_MALI_BIFROST=y
CONFIG_ROCKCHIP_RKNPU=y
CONFIG_ROCKCHIP_MPP_SERVICE=y
CONFIG_RTC_DRV_PCF8563=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_DW_WATCHDOG=y
CONFIG_SOFTLOCKUP_DETECTOR=y
CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y
CONFIG_DETECT_HUNG_TASK=y
CONFIG_BOOTPARAM_RCU_STALL_PANIC=y
EOF
kcase_on() {
    cp "$T"/kernel.config "$T"/kernel.mut
    subst "$T"/kernel.mut "# CONFIG_$1 is not set" "CONFIG_$1=$2"
    expect_fail "kernel cannot write the loader area or NOR" "CONFIG_$1=$2" "CONFIG_$1 is enabled" "$S"/check-kernel-config.sh "$T"/kernel.mut
}
kcase_off() {
    cp "$T"/kernel.config "$T"/kernel.mut
    subst "$T"/kernel.mut "CONFIG_$1=y" "# CONFIG_$1 is not set"
    expect_fail "kernel keeps the accelerator/diagnostic options" "CONFIG_$1 not set" "CONFIG_$1 is not =y" "$S"/check-kernel-config.sh "$T"/kernel.mut
}
expect_ok "kernel config guard" "fabricated good .config" "$S"/check-kernel-config.sh "$T"/kernel.config
kcase_on ROCKCHIP_VENDOR_STORAGE y
kcase_on ROCKCHIP_VENDOR_STORAGE_UPDATE_LOADER y
kcase_on SPI_ROCKCHIP_SFC y
kcase_on MTD_SPI_NOR m
kcase_on FIQ_DEBUGGER y
kcase_on DEVMEM y
kcase_on MMC_TEST m
cp "$T"/kernel.config "$T"/kernel.mut
echo 'CONFIG_ROCKCHIP_MMC_VENDOR_STORAGE=y' >>"$T"/kernel.mut
expect_fail "kernel cannot write the loader area or NOR" "CONFIG_ROCKCHIP_MMC_VENDOR_STORAGE=y" "CONFIG_ROCKCHIP_MMC_VENDOR_STORAGE is enabled" "$S"/check-kernel-config.sh "$T"/kernel.mut
for s in MALI_BIFROST ROCKCHIP_RKNPU ROCKCHIP_MPP_SERVICE RTC_DRV_PCF8563 PSTORE_RAM PSTORE_CONSOLE DW_WATCHDOG \
    SOFTLOCKUP_DETECTOR BOOTPARAM_SOFTLOCKUP_PANIC DETECT_HUNG_TASK BOOTPARAM_RCU_STALL_PANIC; do
    kcase_off "$s"
done

# --- loader binaries

lb_fresh() {
    rm -rf "$T"/lb
    mkdir -p "$T"/lb/images "$T"/lb/target/usr/bin
    echo data >"$T"/lb/images/u-boot.itb
    echo '#!/bin/sh' >"$T"/lb/target/usr/bin/tool
}
lb_case() {
    lb_fresh
    "$2"
    expect_fail "no loader binary in images/ or the rootfs" "$1" "check-no-loader-binaries: FAIL" "$S"/check-no-loader-binaries.sh "$T"/lb/images "$T"/lb/target
}
lb_fresh
expect_ok "no loader binary in images/ or the rootfs" "clean images and rootfs" "$S"/check-no-loader-binaries.sh "$T"/lb/images "$T"/lb/target
lb_idbloader() { echo x >"$T"/lb/images/idbloader.img; }
lb_rockchip() { echo x >"$T"/lb/images/u-boot-rockchip.bin; }
lb_rockchip_spi() { echo x >"$T"/lb/images/u-boot-rockchip-spi.bin; }
lb_spl() { echo x >"$T"/lb/images/u-boot-spl.bin; }
lb_tpl() { echo x >"$T"/lb/images/rk3566_tpl.bin; }
lb_target_idb() { echo x >"$T"/lb/target/usr/bin/idbloader.img; }
lb_rkns() { printf 'RKNS\0\0\0\0rest' >"$T"/lb/target/usr/bin/innocent; }
lb_case "images/idbloader.img" lb_idbloader
lb_case "images/u-boot-rockchip.bin" lb_rockchip
lb_case "images/u-boot-rockchip-spi.bin" lb_rockchip_spi
lb_case "images/u-boot-spl.bin" lb_spl
lb_case "images/rk3566_tpl.bin" lb_tpl
lb_case "target/usr/bin/idbloader.img" lb_target_idb
lb_case "idblock (RKNS magic) under an innocent name in the rootfs" lb_rkns

# --- result

awk -F'\t' 'BEGIN { printf "%-50s %-52s %s\n", "INVARIANT", "VIOLATION TRIED", "GUARD RESULT" }
    { printf "%-50s %-52s %s\n", substr($1, 1, 50), substr($2, 1, 52), $3 }' "$ROWS"
total=$(wc -l <"$ROWS")
if [ "$FAILS" -ne 0 ]; then
    echo "test-guards: $FAILS of $total checks FAILED" >&2
    exit 1
fi
if [ "$SKIPS" -ne 0 ]; then
    echo "test-guards: all $total checks behaved; $SKIPS SKIPPED (no strace or a syscall unavailable here): the write-syscall trace was not fully tested" >&2
else
    echo "test-guards: all $total checks behaved"
fi
