# Changelog

## v0.1.0

Initial Rubik Pi 3 (QCS6490) target, forked from the `dragon_q6a` target:
mainline Linux 7.1, EDK2 UEFI + GRUB2 (arm64-efi) boot chain with A/B
rootfs slots, onboard 128 GB UFS boot disk.

Since this target has not shipped before, it goes out with the PR #17 fwup
fixes already applied: `NERVES_FW_APPLICATION_PART0_TARGET` set to the
canonical `/root` (matching what `/proc/mounts` reports for the `/data`
symlink, so nerves_runtime's Init never mis-detects the app partition as
unmounted and reformats it), and the layout/identity fwup keys (devpath,
part0 devpath/fstype/target, platform, architecture) hardened to
`define!()` so environment variables can't silently override them.
