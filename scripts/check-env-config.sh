#!/bin/sh
#
# U-Boot, fwup and fw_printenv each locate the single env block on their
# own. If any of them disagree on where it is or how big it is, U-Boot boots
# on its default env forever (no A/B, no revert) or nerves_runtime reads
# garbage, and nothing fails until hardware. This keeps them in lockstep.
#
# Usage: scripts/check-env-config.sh [repo dir]

set -e

DIR=${1:-$(cd "$(dirname "$0")/.." && pwd)}
FRAGMENT=$DIR/uboot/ufs.fragment
FWUP_COMMON=$DIR/fwup_include/fwup-common.conf
UBOOT_ENV=$DIR/uboot/uboot.env
DEFCONFIG=$DIR/nerves_defconfig
FW_ENV=$DIR/rootfs_overlay/etc/fw_env.config

fail() {
    echo "check-env-config: $*" >&2
    exit 1
}

# Prints the value of define!(NAME, value) from fwup-common.conf, quotes
# stripped.
fwup_define() {
    sed -n "s/^define!($1, *\"\{0,1\}\([^\")]*\)\"\{0,1\}).*/\1/p" "$FWUP_COMMON"
}

is_uint() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
}

# Accepts decimal or 0x-prefixed hex; prints decimal or nothing.
to_dec() {
    case $1 in
        0x* | 0X*) printf '%d' "$1" 2>/dev/null || true ;;
        *) is_uint "$1" && echo "$1" ;;
    esac
}

lower() {
    echo "$1" | tr 'A-F' 'a-f'
}

# (a) env partition GUID
uboot_uuid=$(sed -n 's/^CONFIG_ENV_SCSI_PART_UUID="\([^"]*\)".*/\1/p' "$FRAGMENT")
fwup_uuid=$(fwup_define UBOOT_ENV_PART_GUID)
env_uuid=$(sed -n 's/^nerves_env_uuid=\(.*\)$/\1/p' "$UBOOT_ENV")

[ -n "$uboot_uuid" ] || fail "no CONFIG_ENV_SCSI_PART_UUID in $FRAGMENT"
[ -n "$fwup_uuid" ] || fail "no define!(UBOOT_ENV_PART_GUID, ...) in $FWUP_COMMON"
[ -n "$env_uuid" ] || fail "no nerves_env_uuid in $UBOOT_ENV"

# Compared exactly at boot against U-Boot's lowercase `part uuid`, so it can't be case-folded like the others.
case $env_uuid in
    *[A-Z]*) fail "nerves_env_uuid=$env_uuid ($UBOOT_ENV) must be lowercase: the boot script compares it exactly against U-Boot's lowercase 'part uuid' output" ;;
esac

uboot_uuid=$(lower "$uboot_uuid")
fwup_uuid=$(lower "$fwup_uuid")
env_uuid=$(lower "$env_uuid")
if [ "$uboot_uuid" != "$fwup_uuid" ] || [ "$uboot_uuid" != "$env_uuid" ]; then
    fail "env partition GUID mismatch: CONFIG_ENV_SCSI_PART_UUID=$uboot_uuid ($FRAGMENT), UBOOT_ENV_PART_GUID=$fwup_uuid ($FWUP_COMMON), nerves_env_uuid=$env_uuid ($UBOOT_ENV)"
fi

# (b) env size
uboot_size=$(to_dec "$(sed -n 's/^CONFIG_ENV_SIZE=\(.*\)$/\1/p' "$FRAGMENT")")
env_count=$(fwup_define UBOOT_ENV_COUNT)
image_size=$(sed -n 's/^BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE_SIZE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$DEFCONFIG")

# First non-comment line: device, offset, size.
fw_env_line=$(grep -v '^[[:space:]]*\(#\|$\)' "$FW_ENV" | head -n 1)
# shellcheck disable=SC2086 # split the line into fields
set -- $fw_env_line
fw_env_offset=$(to_dec "$2")
fw_env_size=$(to_dec "$3")

[ -n "$uboot_size" ] || fail "no numeric CONFIG_ENV_SIZE in $FRAGMENT"
is_uint "$env_count" || fail "no numeric define!(UBOOT_ENV_COUNT, ...) in $FWUP_COMMON"
is_uint "$image_size" || fail "no numeric BR2_PACKAGE_HOST_UBOOT_TOOLS_ENVIMAGE_SIZE in $DEFCONFIG"
if [ -z "$fw_env_offset" ] || [ -z "$fw_env_size" ]; then
    fail "no device/offset/size line in $FW_ENV"
fi

fwup_size=$((env_count * 512))
if [ "$uboot_size" -ne "$fwup_size" ] || [ "$uboot_size" -ne "$image_size" ] || [ "$uboot_size" -ne "$fw_env_size" ]; then
    fail "env size mismatch: CONFIG_ENV_SIZE=$uboot_size ($FRAGMENT), UBOOT_ENV_COUNT*512=$fwup_size ($FWUP_COMMON), ENVIMAGE_SIZE=$image_size ($DEFCONFIG), size column=$fw_env_size ($FW_ENV)"
fi

# (c) env offset: fw_env.config addresses the whole disk, and U-Boot reads
# from p1's first byte.
env_offset=$(fwup_define UBOOT_ENV_OFFSET)
part_offset=$(fwup_define ENV_PART_OFFSET)
is_uint "$env_offset" || fail "no numeric define!(UBOOT_ENV_OFFSET, ...) in $FWUP_COMMON"
is_uint "$part_offset" || fail "no numeric define!(ENV_PART_OFFSET, ...) in $FWUP_COMMON"

if [ "$env_offset" -ne "$part_offset" ]; then
    fail "UBOOT_ENV_OFFSET=$env_offset but ENV_PART_OFFSET=$part_offset ($FWUP_COMMON); U-Boot reads the env from the start of p1"
fi
if [ $((env_offset * 512)) -ne "$fw_env_offset" ]; then
    fail "env offset mismatch: UBOOT_ENV_OFFSET*512=$((env_offset * 512)) ($FWUP_COMMON), offset column=$fw_env_offset ($FW_ENV)"
fi

echo "check-env-config: OK (GUID $uboot_uuid, $uboot_size bytes at byte $fw_env_offset)"
