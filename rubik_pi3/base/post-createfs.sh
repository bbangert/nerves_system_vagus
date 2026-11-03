#!/bin/sh

set -e

# Not $NERVES_DEFCONFIG_DIR: vendored under <product>/base/, that names the
# product directory, not this one.
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)
FWUP_CONFIG=$BOARD_DIR/fwup.conf

# Run the common post-image processing for nerves
"$BR2_EXTERNAL_NERVES_PATH"/board/nerves-common/post-createfs.sh "$TARGET_DIR" "$FWUP_CONFIG"
