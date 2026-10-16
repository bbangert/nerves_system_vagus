<!--
  SPDX-FileCopyrightText: None
  SPDX-License-Identifier: CC0-1.0
-->
# Changelog

This project does NOT follow semantic versioning. The version increases as
follows:

1. Major version updates are breaking updates to the build infrastructure.
   These should be very rare.
2. Minor version updates are made for every major Buildroot release. This
   may also include Erlang/OTP and Linux kernel updates. These are made four
   times a year shortly after the Buildroot releases.
3. Patch version updates are made for Buildroot minor releases, Erlang/OTP
   releases, and Linux kernel updates. They're also made to fix bugs and add
   features to the build infrastructure.

## v0.2.0

Repo tag v0.5.0. podman replaces balenaEngine as the container engine, and
nftables replaces iptables. No other change on this target. Build-proof only
so far: the device gates (migration from balenaEngine, A/B revert, reboots)
run with the Vagus release that switches to podman.

* **podman 6.1.4 replaces balenaEngine v25.0.14.** The image ships podman
  (rootful, built without systemd), netavark 2.1.0 (nftables driver; no
  aardvark-dns, so container DNS is off), crun 1.30.1, Buildroot's conmon
  2.1.8 and catatonit 0.2.1, and Buildroot's containers-image-config
  (`policy.json` accepts any image; `registries.conf` searches only
  `docker.io` for short names). The recipes live in `shared/package/` and
  `make sync` copies them here. **Breaking:** `balena-engine*`, its socket
  and the `balena-engine` system user are gone; this system needs a Vagus
  that drives podman.
* `/etc/containers/containers.conf` and `storage.conf` are baked in:
  graphroot `/root/containers/storage`, runroot `/run/containers/storage`,
  `transient_store = true`, the events file at
  `/run/libpod/events/events.log` (4 MiB cap), and the frugal pull settings
  (one layer at a time, spool under the graphroot). Vagus overrides the
  per-board settings at boot through `CONTAINERS_CONF_OVERRIDE`.
* **nftables.** The container kernel fragment gains `NF_TABLES`,
  `NF_TABLES_INET`, `NF_CONNTRACK_MARK`, `NFT_CT`, `NFT_NAT`, `NFT_MASQ` and
  `NFT_FIB_IPV4`/`IPV6`/`INET`, plus the namespace, cgroup and POSIX mqueue
  symbols balenaEngine's kernel fixups used to set. `nft` (with JSON) is in
  the image.
* **iptables removed.** The userland (`iptables-legacy`, `/usr/lib/xtables`,
  `libxtables`, `libip4tc`, `libip6tc`) and the legacy xtables kernel
  symbols (`NETFILTER_XTABLES_LEGACY`, `IP_NF_*`, `IP6_NF_*`,
  `NETFILTER_XT_NAT`, `NETFILTER_XT_TARGET_MASQUERADE`,
  `NETFILTER_XT_MARK`) are gone. **Breaking** for anything that runs
  `iptables`.
* util-linux is now enabled in the defconfig rather than through
  balenaEngine's selects: `mount`, `swapon`, `mkswap`, `mountpoint` and
  `pivot_root` stay, and `nsenter` is added. `cgroupfs-mount` is gone.

## v0.1.5

Repo tag v0.4.0. Security updates and a container-engine fix. No kernel or
configuration change on this target. Validated on hardware 2026-10-12 (OTA,
A/B revert, ethernet, Bluetooth, container stack); WiFi association not
exercised.

* `nerves_system_br` 1.34.0 → 1.34.4: Buildroot 2026.05 → 2026.05.2 and
  Erlang/OTP 29.0.2 → 29.0.6, both security updates. The Buildroot move
  includes wpa_supplicant 2.11 → 2.12, OpenSSL 3.6.2 → 3.6.3, expat 2.8.1
  → 2.8.3 and GLib 2.86.5 → 2.88.3.
* balenaEngine `d7af640` → `338143c` (still v25.0.14; the commit
  meta-balena pins). The one source change: volume options are saved with an
  atomic write, so a power cut can no longer leave a truncated `opts.json`
  that stops the daemon starting.

## v0.1.4

Kernel memory tuning via the new shared `shared/linux-memory.config`
fragment (synced to all 11 targets) and a shared `shared/sysctl.conf`.
Kernel-config change on a previously-working board — the merged `.config`
is audited (every fragment symbol grepped in the merged config) and the
existing capability smoke set is re-run on device before the tag. THP is
untouched: this tree doesn't build it. Closes #18 (kernel half).

* Fragment symbols relevant to this 6.18 tree: `PSI` (+ `/proc/pressure/*`
  live), `LRU_GEN` + `LRU_GEN_ENABLED` (MGLRU on by default, runtime kill
  switch at `/sys/kernel/mm/lru_gen/enabled`), `ZRAM`/`ZSWAP` + LZ4
  (backend and default compressor respectively), and `BLK_DEV_RAM` off
  (this defconfig had it on — 16 unused ramdisk devices; Nerves boots
  squashfs directly). `SWAP` was already on by kernel default and is now
  confirmed explicitly in the fragment.
* **`shared/sysctl.conf` is now the canonical overlay file for every
  target.** Removes this file's `vm.swappiness = 10` and the "RAM-tight
  1GB Pi 3B+ ... with a swapfile" rationale that justified it — this board
  has never had a swapfile, so swappiness was always inert here.
  `vm.swappiness` is now set at runtime by `Vagus.Host.Swap` (vagus 0.9.0),
  once it ships. Adds `vm.dirty_background_bytes = 16 MiB` /
  `vm.dirty_bytes = 64 MiB` in place of the ratio defaults, protecting the
  SD card from write storms.

## v0.1.3

fwup metadata fix (PR #17): `NERVES_FW_APPLICATION_PART0_TARGET` corrected
to the canonical `/root`, matching what `/proc/mounts` reports for the
`/data` symlink, so nerves_runtime's Init never mis-detects the app
partition as unmounted and runs `mkfs` against it. Layout/identity fwup
keys (devpath, part0 devpath/fstype/target, platform, architecture)
hardened to `define!()` so environment variables can't silently override
them.

## v0.1.2

`e2fsprogs`' `resize2fs` added to the system image (PR #14), extended from
`dragon_q6a`-only to every target.

## v0.1.1

Build-infrastructure fixes made while porting the container runtime to
`dragon_q6a`. No functional change to the running system.

* **Artifact-checksum gap closed (bug).** `package_files()` — which is the
  Nerves artifact `:checksum` input, not just the hex manifest — omitted
  `Config.in`, `external.mk`, `package/` and `linux-containers.config`.
  Editing the `vagus-balena-engine` recipe or the container kernel fragment
  therefore did **not** invalidate the cached artifact, so a rebuild could
  silently keep shipping a stale engine binary. All four are now listed.
* `linux-containers.config` moved to `shared/` and is materialized back here
  by `make sync` (drift-checked by `make check`), so the fragment is
  maintained in one place now that `dragon_q6a` consumes it too. The synced
  content is identical apart from the dead `CONFIG_NF_NAT_IPV4` line, which
  was dropped — it is not a Kconfig symbol in this kernel (mainline folded
  IPv4 NAT into `CONFIG_NF_NAT` in 5.1), so it never had any effect.
* `mix.exs` reformatted (`mix format`).

## v0.1.0

Initial release of `nerves_system_rpi3_64`, a new 64-bit Nerves system for the
Raspberry Pi 3 Model A+/B/B+, forked from `nerves_system_rpi0_2` (same
BCM2837/Cortex-A53 SoC family, already aarch64) with board-specific bits
(rpi-firmware variant, kernel DTBs, `config.txt` overlays, `boardid.config`,
`fw_env.config`) ported over from `nerves_system_rpi3`.

* Inherited from `nerves_system_rpi0_2`
  * aarch64 toolchain (`nerves_toolchain_aarch64_nerves_linux_gnu` 15.3.0)
  * `nerves_system_br` 1.34.0, Linux 6.18 (Raspberry Pi 1.20260521 tag)
  * VC4 KMS graphics (`vc4-kms-v3d`), libcamera-based camera support
  * BlueZ + D-Bus Bluetooth stack, USB audio via `bluez-alsa`

* Ported from `nerves_system_rpi3`
  * `rpi-firmware` extended variant only (`VARIANT_PI_X`)
  * Kernel DTBs limited to the Pi 3 set: `bcm2710-rpi-3-b`,
    `bcm2710-rpi-3-b-plus`
  * Official 7" touchscreen overlays (`rpi-ft5406`, `rpi-backlight`)
  * HDMI (`tty1`) as the default IEx console, since the Pi 3 (unlike the Zero
    2 W) is commonly used with an attached display and keyboard
  * `boardid.config` / `fw_env.config` board identifiers


## Previous releases

This is a fork of [nerves_system_rpi0_2](https://github.com/nerves-project/nerves_system_rpi0_2)
(itself derived from `nerves_system_rpi3a`), with Raspberry Pi 3-specific board
bits ported from [nerves_system_rpi3](https://github.com/nerves-project/nerves_system_rpi3).
See those projects for pre-fork history.
