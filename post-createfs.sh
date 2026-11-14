#!/bin/sh

set -e

# See post-build.sh: NERVES_DEFCONFIG_DIR is the product dir when vendored.
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)

FWUP_CONFIG="$BOARD_DIR"/fwup.conf

# Run the common post-image processing for nerves
"$BR2_EXTERNAL_NERVES_PATH"/board/nerves-common/post-createfs.sh "$TARGET_DIR" "$FWUP_CONFIG"

# The system build never makes a .fw (mix firmware does, in the product), so
# build one from the final images, throwaway, to hold the real fwup.conf to
# the loader-area rule. Inside $BASE_DIR, not /tmp: the dynamic check writes
# the whole rootfs to a scratch disk image.
FWUP=$HOST_DIR/usr/bin/fwup
export FWUP
GUARD_TMP=$(mktemp -d "$BASE_DIR"/guard.XXXXXX)
trap 'rm -rf "$GUARD_TMP"' EXIT
NERVES_SYSTEM=$BASE_DIR NERVES_SDK_IMAGES=$BINARIES_DIR NERVES_SDK_VERSION=guard \
    NERVES_FW_VCS_IDENTIFIER=guard NERVES_FW_MISC="" \
    "$FWUP" -c -f "$FWUP_CONFIG" -o "$GUARD_TMP"/system.fw
# ops.fw is traced against the disk image complete lays down.
TMPDIR=$GUARD_TMP "$BOARD_DIR"/scripts/check-loader-area.sh "$GUARD_TMP"/system.fw \
    "$TARGET_DIR"/usr/share/fwup/ops.fw
