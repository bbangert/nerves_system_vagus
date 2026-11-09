#!/usr/bin/env bash
# Usage: scripts/flash-ufs.sh <firmware.fw> /dev/sdX [--yes]
#
# Writes a firmware image to a Radxa UFS module sitting in a USB reader,
# regenerating the GPT for the module's 4096-byte LBAs (see tools/mk_ufs_image.py).
set -euo pipefail

usage() { echo "usage: $0 <firmware.fw> /dev/sdX [--yes]" >&2; exit 2; }
die() { echo "error: $*" >&2; exit 1; }

yes=0
args=()
for a in "$@"; do
  if [ "$a" = "--yes" ]; then yes=1; else args+=("$a"); fi
done
[ "${#args[@]}" -eq 2 ] || usage
fw=${args[0]}
# Canonical /dev/sdX so by-id paths match /sys/block and /proc/self/mounts.
dev=$(readlink -f "${args[1]}")

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ -f "$fw" ] || die "$fw is not a file"
[ -b "$dev" ] || die "$dev is not a block device"
for tool in fwup python3 blockdev dd lsblk; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
name=$(basename "$dev")

# A partition like sdb1 has no /sys/block entry of its own; refusing it here
# also stops a typo from clobbering one partition of a larger disk.
[ -e "/sys/block/$name" ] || die "$dev is not a whole disk"

sysdev=$(readlink -f "/sys/block/$name")
removable=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
case $sysdev in
  */usb*) usb=1 ;;
  *) usb=0 ;;
esac
if [ "$removable" != 1 ] && [ "$usb" != 1 ]; then
  die "$dev is neither removable nor USB-attached; refusing"
fi

# Everything stacked on the target counts as the target: a filesystem on
# LVM/dm-crypt/md over one of its partitions is a live use of the disk, but its
# mount source is /dev/dm-N, which a name match on $dev would never see.
# Fails closed: if the descendant tree can't be listed, nothing is verified.
# /proc/self/mounts rather than lsblk MOUNTPOINTS (util-linux >= 2.37), whose
# failure would silently pass the guard.
refuse_if_in_use() {
  local disk=$1 name tree d h src mnt
  local -A members=()
  name=$(basename "$disk")

  # Holders are registered by dm, md and LVM alike, mounted or not.
  shopt -s nullglob
  for h in "/sys/block/$name/holders/"* "/sys/block/$name/$name"*/holders/*; do
    die "$disk is in use by $(basename "$h") (stacked block device); refusing"
  done
  shopt -u nullglob

  tree=$(lsblk -nrpo NAME "$disk") || die "lsblk failed on $disk; cannot verify it is unused"
  [ -n "$tree" ] || die "lsblk listed nothing for $disk; cannot verify it is unused"
  while read -r d; do
    members[$(readlink -f "$d" 2>/dev/null || echo "$d")]=1
  done <<<"$tree"

  while read -r src mnt _; do
    src=$(readlink -f "$src" 2>/dev/null || echo "$src")
    [ -z "${members[$src]:-}" ] || die "$disk (or a device stacked on it) is mounted at $mnt"
  done </proc/self/mounts

  # Swap on the target is equally live; the first line is a header.
  while read -r src _; do
    src=$(readlink -f "$src" 2>/dev/null || echo "$src")
    [ -z "${members[$src]:-}" ] || die "$disk (or a device stacked on it) is active swap"
  done < <(tail -n +2 /proc/swaps)
}
refuse_if_in_use "$dev"

root_src=$(findmnt -nro SOURCE / || true)
if [ -n "$root_src" ]; then
  root_disk=$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -n1 || true)
  [ -n "$root_disk" ] || root_disk=$(basename "$root_src")
  [ "$root_disk" != "$name" ] || die "$dev holds the root filesystem"
fi

disk_bytes=$(blockdev --getsize64 "$dev")
echo "target:      $dev"
echo "disk bytes:  $disk_bytes"
echo "getss/pbsz:  $(blockdev --getss "$dev") $(blockdev --getpbsz "$dev")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Always to a file: fwup's complete task would otherwise write a 512-byte-LBA
# GPT straight onto the device, which the 4Kn module cannot read.
fwup -a -i "$fw" -t complete -d "$tmp/fwup.img"

python3 -I "$repo/tools/mk_ufs_image.py" \
  --input "$tmp/fwup.img" --disk-bytes "$disk_bytes" --out "$tmp/ufs"

img_bytes=$(stat -c %s "$tmp/ufs.img")
backup_offset=$((disk_bytes - 5 * 4096))

echo
echo "About to ERASE and overwrite $dev:"
echo "  $tmp/ufs.img ($img_bytes bytes) -> byte 0"
echo "  backup GPT (20480 bytes)         -> byte $backup_offset"
if [ "$yes" != 1 ]; then
  [ -t 0 ] || die "not a terminal; pass --yes to confirm"
  read -r -p "Type 'y' to continue: " reply
  [ "$reply" = y ] || die "aborted"
fi

# Again: an automounter or swapon can claim the disk while the image builds
# or the prompt waits.
refuse_if_in_use "$dev"
dd if="$tmp/ufs.img" of="$dev" bs=4M conv=fsync status=progress
dd if="$tmp/ufs-backup-gpt.bin" of="$dev" bs=4096 seek="$backup_offset" \
  oflag=seek_bytes conv=fsync status=none
sync

echo
echo "Done: wrote $fw to $dev ($disk_bytes bytes; image $img_bytes bytes, backup GPT at byte $backup_offset)."
