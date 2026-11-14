#!/bin/sh
#
# The boot disk is chosen at run time, so the same image works on the SD card
# and the eMMC, and the SD and eMMC GUID sets differ. Anything that looked a
# partition up by GUID, UUID, label or number-from-GUID would break that. GUID
# definitions in fwup's gpt blocks are fine; lookups are not.
#
# Usage: scripts/check-no-guid-lookup.sh [repo dir]

set -e

DIR=${1:-$(cd "$(dirname "$0")/.." && pwd)}

# Patterns are literal fragments, not regexes.
PATTERNS='PARTUUID
by-partuuid
PARTLABEL
by-partlabel
by-uuid
by-label
part uuid
part number
gpt guid
root=UUID
root=LABEL
LABEL='

# Comments may name what the code avoids; a `#` only starts one at the start
# of a line or after whitespace (U-Boot's `serial#` is a variable name).
scan() {
    sed 's/^[[:space:]]*#.*//; s/[[:space:]]#.*//' "$1" | grep -nF -i -e "$2" |
        sed "s|^|$1:|" || true
}

rc=0
for target in uboot/uboot.env fwup.conf fwup-ops.conf fwup_include \
    rootfs_overlay linux/nerves.config linux/rk3566.config nerves_defconfig; do
    [ -e "$DIR/$target" ] || { echo "check-no-guid-lookup: $target is missing" >&2; rc=1; continue; }
    hits=$(find "$DIR/$target" -type f | while IFS= read -r f; do
        echo "$PATTERNS" | while IFS= read -r p; do scan "$f" "$p"; done
    done)
    if [ -n "$hits" ]; then
        echo "$hits" | sed 's/^/check-no-guid-lookup: FAIL /' >&2
        rc=1
    fi
done
[ "$rc" -eq 0 ] && echo "check-no-guid-lookup: OK"
exit "$rc"
