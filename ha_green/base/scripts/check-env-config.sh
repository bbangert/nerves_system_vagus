#!/bin/sh
#
# U-Boot's boot script, fwup, fw_printenv and the env image each locate the
# one state block, the FIT and the files on the boot FAT on their own. If any
# of them disagree, U-Boot silently boots on its default env (no A/B, no
# revert), userspace reads garbage, or the kernel is not found, and nothing
# fails until hardware. This keeps them in lockstep by reading the literals.
#
# Usage: scripts/check-env-config.sh [repo dir]

set -e

DIR=${1:-$(cd "$(dirname "$0")/.." && pwd)}
FRAGMENT=$DIR/uboot/green.fragment
FWUP_COMMON=$DIR/fwup_include/fwup-common.conf
FWUP=$DIR/fwup.conf
UBOOT_ENV=$DIR/uboot/uboot.env
DEFCONFIG=$DIR/nerves_defconfig
FW_ENV=$DIR/rootfs_overlay/etc/fw_env.config

fail() {
    echo "check-env-config: $*" >&2
    exit 1
}

# define!(NAME, value) from fwup-common.conf, quotes and trailing comment
# stripped.
fwup_define() {
    sed -n "s/^define!($1, *\"\{0,1\}\([^\")]*\)\"\{0,1\}).*/\1/p" "$FWUP_COMMON"
}

# The one value the script uses for a pattern: sed expression with one group,
# run over uboot.env. Fails if the pattern is gone or its uses disagree.
# Third argument "stmts": split into one statement per line first, so a line
# holding several matches is checked in full.
script_value() {
    if [ "${3:-}" = stmts ]; then
        vals=$(sed 's/ *&& */\n/g; s/; */\n/g' "$UBOOT_ENV" | sed -n "$2" | sort -u)
    else
        vals=$(sed -n "$2" "$UBOOT_ENV" | sort -u)
    fi
    [ -n "$vals" ] || fail "$1: pattern not found in $UBOOT_ENV (the script changed shape; update this check)"
    [ "$(echo "$vals" | wc -l)" -eq 1 ] || fail "$1: $UBOOT_ENV uses several values: $(echo "$vals" | tr '\n' ' ')"
    echo "$vals"
}

# Decimal for decimal or 0x-hex input, empty otherwise.
to_dec() {
    case $1 in
        '' | *[!0-9a-fA-FxX]*) return 0 ;;
        0x* | 0X*) printf '%d' "$1" 2>/dev/null || true ;;
        *[!0-9]*) return 0 ;;
        *) echo "$1" ;;
    esac
}

need_num() {
    [ -n "$(to_dec "$2")" ] || fail "no numeric $1 (got '$2')"
}

dec() {
    need_num "$1" "$2"
    to_dec "$2"
}

# --- state block: location

# The 0x count operand tells the state block from the 1-block FIT probe, whatever the address.
read_args=$(script_value "state read" 's/.*mmc read [^ ]* \(0x[0-9a-fA-F]*\) \(0x[0-9a-fA-F]*\).*/\1 \2/p' stmts)
write_args=$(script_value "state write" 's/.*mmc write [^ ]* \(0x[0-9a-fA-F]*\) \(0x[0-9a-fA-F]*\).*/\1 \2/p' stmts)
[ "$read_args" = "$write_args" ] || fail "boot script reads the state with '$read_args' but writes it with '$write_args'"
# shellcheck disable=SC2086 # two fields
set -- $read_args
script_lba=$(dec "script state LBA" "$1")
script_blocks=$(dec "script state blocks" "$2")

env_offset=$(dec "UBOOT_ENV_OFFSET" "$(fwup_define UBOOT_ENV_OFFSET)")
env_count=$(dec "UBOOT_ENV_COUNT" "$(fwup_define UBOOT_ENV_COUNT)")
part_offset=$(dec "ENV_PART_OFFSET" "$(fwup_define ENV_PART_OFFSET)")

# First non-comment line: device, offset, size.
fw_env_line=$(grep -v '^[[:space:]]*\(#\|$\)' "$FW_ENV" | head -n 1)
# shellcheck disable=SC2086 # split the line into fields
set -- $fw_env_line
fw_env_offset=$(dec "fw_env.config offset" "$2")
fw_env_size=$(dec "fw_env.config size" "$3")

[ "$script_lba" -eq "$env_offset" ] || fail "state LBA: boot script $script_lba, UBOOT_ENV_OFFSET $env_offset ($FWUP_COMMON)"
[ "$env_offset" -eq "$part_offset" ] || fail "UBOOT_ENV_OFFSET=$env_offset but ENV_PART_OFFSET=$part_offset ($FWUP_COMMON); the state block is the start of p1"
[ $((env_offset * 512)) -eq "$fw_env_offset" ] || fail "state offset: UBOOT_ENV_OFFSET*512=$((env_offset * 512)), fw_env.config says $fw_env_offset ($FW_ENV)"

# --- state block: size (U-Boot and fwup both CRC size - 4 bytes)

# -c imports/exports are the state block; -t ones (the crumb) have no size operand here.
import_size=$(dec "script env import size" "$(script_value "env import" 's/.*env import -c [^ ]* \(0x[0-9a-fA-F]*\).*/\1/p' stmts)")
export_size=$(dec "script env export size" "$(script_value "env export" 's/.*env export -c -s \(0x[0-9a-fA-F]*\) .*/\1/p' stmts)")
clear_size=$(dec "script buffer clear size" "$(script_value "buffer clear" 's/.*mw\.b [^ ]* 0 \(0x[0-9a-fA-F]*\).*/\1/p' stmts)")
frag_size=$(dec "CONFIG_ENV_SIZE" "$(sed -n 's/^CONFIG_ENV_SIZE=\(.*\)$/\1/p' "$FRAGMENT")")
image_size=$(dec "ENVIMAGE_SIZE" "$(sed -n 's/^BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE_SIZE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DEFCONFIG")")

size=$((env_count * 512))
for pair in "script blocks*512:$((script_blocks * 512))" "script env import:$import_size" \
    "script env export:$export_size" "script buffer clear:$clear_size" \
    "CONFIG_ENV_SIZE:$frag_size" "ENVIMAGE_SIZE:$image_size" "fw_env.config size:$fw_env_size"; do
    [ "${pair#*:}" -eq "$size" ] || fail "state size: UBOOT_ENV_COUNT*512=$size ($FWUP_COMMON) but ${pair%%:*}=${pair#*:}"
done

# --- FIT

probe_lba=$(dec "script SD probe LBA" "$(script_value "SD probe" 's/.*mmc read [$]{nerves_scratch_addr} \(0x[0-9a-fA-F]*\) 1 .*/\1/p')")
fit_offset=$(dec "FIT_OFFSET" "$(fwup_define FIT_OFFSET)")
fit_count=$(dec "FIT_COUNT" "$(fwup_define FIT_COUNT)")
[ "$probe_lba" -eq "$fit_offset" ] || fail "FIT LBA: boot script probes $probe_lba, FIT_OFFSET is $fit_offset"
[ "$fit_offset" -eq 16384 ] || fail "FIT_OFFSET=$fit_offset; the stock SPL loads the FIT from LBA 16384"
[ $((fit_offset + fit_count)) -le "$env_offset" ] || fail "FIT window (LBA $fit_offset + $fit_count) overlaps the state block at LBA $env_offset"

# --- file names on the boot FAT

kernel_tmpl=$(script_value "kernel name" 's/.*load mmc [$]{nerves_disk}:2 [$]{kernel_addr_r} \([^ ]*\) .*/\1/p')
dtb_tmpl=$(script_value "dtb name" 's/.*load mmc [$]{nerves_disk}:2 [$]{fdt_addr_r} \([^ ;]*\)$/\1/p')
dts_name=$(sed -n 's/^BR2_LINUX_KERNEL_INTREE_DTS_NAME="[^"]*\/\([^"\/]*\)"$/\1/p' "$DEFCONFIG")
[ -n "$dts_name" ] || fail "no BR2_LINUX_KERNEL_INTREE_DTS_NAME in $DEFCONFIG"
dtb_host=$(sed -n '/^file-resource devicetree.dtb/,/^}/s|.*host-path = "[$]{NERVES_SYSTEM}/images/\([^"]*\)".*|\1|p' "$FWUP")
[ "$dtb_host" = "$dts_name.dtb" ] || fail "fwup.conf devicetree.dtb host-path is '$dtb_host' but nerves_defconfig builds $dts_name.dtb"

expected=""
for slot in a b; do
    k=$(echo "$kernel_tmpl" | sed "s/[\$]{nerves_slot}/$slot/")
    d=$(echo "$dtb_tmpl" | sed "s/[\$]{nerves_slot}/$slot/")
    [ "$d" = "$dts_name.$slot.dtb" ] || fail "boot script loads '$d' but fwup writes $dts_name.$slot.dtb"
    expected="$expected $k $d"
done
written=$(sed -n 's/.*fat_write([$]{BOOT_PART_OFFSET}, "\([^"]*\)").*/\1/p' "$FWUP" | sort -u)
for n in $expected; do
    echo "$written" | grep -qxF "$n" || fail "boot script loads $n from the boot FAT but fwup.conf never writes it"
done
for n in $written; do
    case " $expected " in
        *" $n "*) ;;
        *) fail "fwup.conf writes $n to the boot FAT but the boot script never loads it" ;;
    esac
done

itb_name=$(sed -n 's/^BR2_TARGET_UBOOT_FORMAT_CUSTOM_NAME="\(.*\)"$/\1/p' "$DEFCONFIG")
itb_host=$(sed -n '/^file-resource u-boot.itb/,/^}/s|.*host-path = "[$]{NERVES_SYSTEM}/images/\([^"]*\)".*|\1|p' "$FWUP")
[ "$itb_name" = "$itb_host" ] || fail "nerves_defconfig builds '$itb_name' but fwup.conf installs '$itb_host'"

echo "check-env-config: OK (state LBA $env_offset x $size bytes, FIT LBA $fit_offset, $expected)"
