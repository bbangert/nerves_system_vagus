#!/bin/sh

set -e

# Vendored under <product>/base/, NERVES_DEFCONFIG_DIR names the product dir,
# so this system's own files are located relative to this script.
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=$BOARD_DIR/scripts
FWUP=$HOST_DIR/usr/bin/fwup
export FWUP

"$SCRIPTS"/check-env-config.sh "$BOARD_DIR"
"$SCRIPTS"/check-no-guid-lookup.sh "$BOARD_DIR"

# Create the fwup ops script for on-device firmware operations (revert,
# validate, factory-reset, status)
# NOTE: revert.fw is the previous, more limited version of this. ops.fw is
#       backwards compatible.
mkdir -p "$TARGET_DIR"/usr/share/fwup
"$FWUP" -c -f "$BOARD_DIR"/fwup-ops.conf -o "$TARGET_DIR"/usr/share/fwup/ops.fw
ln -sf ops.fw "$TARGET_DIR"/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf "$BOARD_DIR"/fwup_include "$BINARIES_DIR"

# Linux and U-Boot are built and installed to images/ by now, so their final
# configs and outputs can be checked here; the .fw files cannot (see
# post-createfs.sh), except ops.fw.
"$SCRIPTS"/check-loader-area.sh --static-only "$TARGET_DIR"/usr/share/fwup/ops.fw
"$SCRIPTS"/check-kernel-config.sh "$BASE_DIR"/build/linux-custom/.config
"$SCRIPTS"/check-fit.sh --config "$BASE_DIR"/build/uboot-custom/.config \
    "$BINARIES_DIR"/u-boot.itb "$BOARD_DIR"/uboot/stock-fit-contract.txt
"$SCRIPTS"/check-no-loader-binaries.sh "$BINARIES_DIR" "$TARGET_DIR"
