#!/bin/sh

set -e

# Vendored under <product>/base/, NERVES_DEFCONFIG_DIR names the product dir,
# so this system's own files are located relative to this script.
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)

"$BOARD_DIR"/scripts/check-env-config.sh "$BOARD_DIR"

# Create the fwup ops script for on-device firmware operations (revert,
# validate, factory-reset, status)
# NOTE: revert.fw is the previous, more limited version of this. ops.fw is
#       backwards compatible.
mkdir -p "$TARGET_DIR"/usr/share/fwup
# fwup-ops.conf finds the extlinux files through NERVES_DEFCONFIG_DIR.
NERVES_DEFCONFIG_DIR="$BOARD_DIR" "$HOST_DIR"/usr/bin/fwup -c -f "$BOARD_DIR"/fwup-ops.conf -o "$TARGET_DIR"/usr/share/fwup/ops.fw
ln -sf ops.fw "$TARGET_DIR"/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf "$BOARD_DIR"/fwup_include "$BINARIES_DIR"

# The bootloader image rock4d-bootloader compares the SPI NOR against and
# writes on request; U-Boot has been built by the time post-build runs.
mkdir -p "$TARGET_DIR"/usr/share/rock4d
cp "$BINARIES_DIR"/u-boot-rockchip-spi.bin "$TARGET_DIR"/usr/share/rock4d/
(cd "$TARGET_DIR"/usr/share/rock4d && sha256sum u-boot-rockchip-spi.bin >u-boot-rockchip-spi.bin.sha256)
