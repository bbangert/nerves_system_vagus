# Changelog

## v0.3.2

fwup metadata fix (PR #17) closing a latent data-loss bug in the
application-partition mount check, plus hardening against build-environment
overrides.

* **`NERVES_FW_APPLICATION_PART0_TARGET` corrected from `/data` (a rootfs
  symlink to `root`) to the canonical `/root`**, exactly as reported in
  `/proc/mounts`. nerves_runtime's Init compares that string literally
  against `/proc/mounts` to decide whether the app partition is mounted;
  with the alias it concluded `:unmounted` on every boot and ran
  `mkfs.ext4 -F` against the live, mounted data partition each boot -- only
  mkfs's own refusal to format a mounted device prevented data loss.
  erlinit still mounts via the `/data` alias; on-disk layout and
  application `/data` paths are unchanged.
* Layout/identity fwup keys (devpath, part0 devpath/fstype/target, platform,
  architecture) hardened to `define!()` so environment variables can't
  silently override them -- fwup's plain `define()` loses to any exported
  env var of the same name.

## v0.3.1

Radxa 25W PoE+ HAT fan support (kernel-automatic, both storage variants),
and a critical fix for fresh flashes.

* **fwup.conf now writes `nerves_fw_validated`** (complete: slot A = 1;
  upgrades: new slot 1 / other slot 0, mirroring rpi3_64). Without it,
  nerves_runtime 0.13.13's StartupGuard reads validation status `:unknown`
  on any freshly complete-flashed board, its heart-callback time bomb never
  clears, and **the board reboot-cycles every ~15 minutes** ("Rebooting in
  11 minutes if unfixed"). Boards OTA'd from older firmware carried a
  legacy global `nerves_fw_validated=1` and never hit this. Field fix for
  an affected board: `Nerves.Runtime.validate_firmware()` once.

* `patches/linux/0004`: two-state `gpio-fan` on GPIO_56 (header pin 33 --
  the HAT's fan-control line; ACTIVE_LOW, the HAT's Q8 inverter makes
  pin-low = fan on) bound to the `cpuss0` thermal zone: on at 60C, off at
  50C. `spi14` is disabled -- its `qup16` pin group owns GPIO_56 and
  Qualcomm's strict pinmux cannot share it (this is why runtime GPIO
  requests for the pin returned EINVAL).
* `CONFIG_SENSORS_GPIO_FAN` m -> y (no module-load dependency for a
  thermal safety device).

## v0.3.0

UFS storage support, device-proven end to end (128 GB module: provisioning,
EDL flash, boot, ethernet, /data at full module size on first boot, A/B OTA
cycle). The same firmware is built to boot from NVMe or UFS; the UFS path is
device-proven in this release, while NVMe re-validation of this exact build
(shared DTB — expect a clean ufshcd probe-failure without a module; GRUB's
`$root`-derived boot disk) is pending that board's next update.

* Kernel: board DTS enables `ufs_mem_hc`/`ufs_mem_phy` (HS-Gear-4 Rate-A,
  ICE off; from Armbian's qcs6490 series) + cherry-pick of upstream
  `3929d18a1aaa` — 7.1's sc7280 HS-G4 PHY init table lacks the PCS writes
  needed for link-up. The DTB is shared with the NVMe variant: with no UFS
  module fitted, ufshcd probes and fails cleanly.
* `tools/mk_ufs_image.py` ("Fork A"): no separate `_4096` fwup config — the
  `.fw` and every on-device path are identical across storage variants; only
  the EDL disk image's GPT is regenerated for 4096-byte LBAs, with `/data`
  sized to the module at generation time. On-device `expand-data` is
  PROHIBITED on UFS boards (fwup's GPT math is 512-LBA-only).
* GRUB: `regexp` added to the builtin modules; grub.cfg derives the boot
  disk from `$root` instead of hardcoding `hd0` (the UFS board enumerates
  as hd2 behind the SPI NOR's GPT — the hardcode left it at the `grub>`
  prompt).
* docs/dragon-q6a-flashing.md: full UFS runbook — one-time LUN provisioning
  for blank modules (armbian/qcombin XML), capacity probing, two-piece
  flash flow, first-boot differences.

## v0.2.0

Container runtime support, bringing this board to rpi3_64 parity as a Vagus
target. Kernel-config change on a previously-working board — the merged
`.config` audit and the existing capability smoke set (fastrpc, Venus, USB3,
`wlan0`/`hci0`, A/B OTA) are both re-run as part of bring-up.

* `package/vagus-balena-engine` — balenaEngine v25.0.14 built with the
  `seccomp` tag, a byte-for-byte copy of rpi3_64's target-local package (the
  recipe is arch- and kernel-agnostic; both boards share the aarch64
  toolchain and `nerves_system_br` 1.34.0). Enabled with
  `BR2_PACKAGE_VAGUS_BALENA_ENGINE=y` + `BR2_PACKAGE_LIBSECCOMP=y`.
* `linux-containers.config` — the container/NAT kernel fragment (overlayfs,
  cgroup controllers, netfilter/legacy-iptables/NAT, bridge/veth, seccomp,
  `CGROUP_BPF`) is now a **shared** fragment (`shared/`, `make sync`,
  drift-checked by `make check`) rather than an rpi3_64-local file, and is
  wired into this board's `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`. The dead
  `CONFIG_NF_NAT_IPV4` line was dropped in the move (not a symbol in either
  kernel tree).
* cgroup v2: `erlinit.config` now mounts `cgroup2` on `/sys/fs/cgroup` and
  `configfs` on `/sys/kernel/config`, and **both** GRUB slots pass
  `cgroup_no_v1=all cgroup_enable=memory`. This board previously had no
  cgroup mount of any kind; the engine daemon cannot start without it.
* `/etc/resolv.conf` is now a symlink to `/run/resolv.conf` (matching
  rpi3_64) instead of the skeleton's `../tmp/resolv.conf`, so the engine
  daemon and containers read the resolver config Vagus writes.
* `mix.exs`: `linux-containers.config` added to `package_files()` so the
  fragment is part of the Nerves artifact checksum.
* `rootfs_overlay/etc/sysctl.conf`: corrected the inherited swappiness
  rationale, which described a 1 GB Pi with a swapfile. The value stays at
  10; it is inert on this board (no swap device configured).

## v0.1.0

Initial release.

* Radxa Dragon Q6A (QCS6490) support: mainline kernel with the in-tree
  `qcom/qcs6490-radxa-dragon-q6a` device tree, EDK2 UEFI → GRUB2 (arm64-efi)
  boot chain with grubenv-driven A/B rootfs slots on a 5-partition GPT
  (config FAT, ESP, rootfs A/B squashfs, /data ext4), NVMe-first.
* AI foundation: linux-firmware qcom blobs plus the matched Dragon Q6A
  CDSP/ADSP firmware set with `.jsn` descriptors (target-local
  `dragon-q6a-firmware` package), fastrpc userspace (library, daemons,
  `fastrpc_test`) as a target-local package, and udev rules for
  fastrpc/dma_heap/video/dri device access. QAIRT is user-provisioned to
  `/data` and deliberately not part of the image.
