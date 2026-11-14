#!/bin/sh
#
# Nothing we build may carry a first-stage loader: it would be one
# misdirected dd away from the board's own. Fails if the images directory
# holds an idbloader/SPL/TPL image or a u-boot-rockchip*.bin, or if a
# Rockchip idblock (magic "RKNS") or such a file is anywhere in the target
# rootfs.
#
# Usage: check-no-loader-binaries.sh <images dir> [target rootfs dir]

set -e

IMAGES=${1:?usage: check-no-loader-binaries.sh <images dir> [target rootfs dir]}
TARGET=$2

found=$(
    find "$IMAGES" \( -iname '*spl*' -o -iname '*tpl*' -o -iname 'idbloader*' \
        -o -iname 'u-boot-rockchip*' \) -type f
    find "$IMAGES" -type f -size +3c -exec sh -c '
        for f; do if [ "$(head -c4 "$f")" = RKNS ]; then echo "$f"; fi; done' sh {} +
    if [ -n "$TARGET" ]; then
        find "$TARGET" -type f \( -iname 'idbloader*' -o -iname 'u-boot-rockchip*' \
            -o -iname '*spl*.bin' -o -iname '*spl*.img' \
            -o -iname '*tpl*.bin' -o -iname '*tpl*.img' \)
        find "$TARGET" -type f -size +3c -exec sh -c '
            for f; do if [ "$(head -c4 "$f")" = RKNS ]; then echo "$f"; fi; done' sh {} +
    fi
)

if [ -n "$found" ]; then
    echo "$found" | sort -u | while read -r f; do
        echo "check-no-loader-binaries: FAIL loader binary: $f" >&2
    done
    exit 1
fi
echo "check-no-loader-binaries: OK"
