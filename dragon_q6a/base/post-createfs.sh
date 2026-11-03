#!/bin/sh

set -e

# See post-build.sh: NERVES_DEFCONFIG_DIR is the product dir when vendored.
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)

FWUP_CONFIG="$BOARD_DIR/fwup.conf"

# Run the common post-image processing for nerves
"$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh" "$TARGET_DIR" "$FWUP_CONFIG"
