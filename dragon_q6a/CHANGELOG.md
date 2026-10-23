# Changelog

Headings are this target's `VERSION`. Git tags are repo-wide and can differ;
an entry names its repo tag where it does.

## v0.6.0

Hardware-debug device classes for the agent-dev-board flavor of Vagus, which
runs hardware tasks in containers: a container brings its own userland, but
only the host kernel can expose a probe, dongle or bus as a device.

* **New kernel fragment `linux-hwdebug.config`** (shared, synced): hidraw and
  hiddev (CMSIS-DAP/DAPLink probes), USB serial `generic`, `simple`, CH341 and
  PL2303, usbmon, USB/IP host, gs_usb and slcan CAN dongles, knfsd (v3 and v4),
  the configfs HID gadget function, IEEE 802.15.4, USB-to-I2C bridges
  (`i2c-tiny-usb`, MCP2221), netem, RNDIS host, and the GPIO cdev v1 ABI.
  Every `depends on` prerequisite is listed explicitly. rootfs +2.5 MiB.
* **nfs-utils with `rpc.nfsd`, `rpc.mountd`, `exportfs` and rpcbind** so a
  target can boot `nfsroot` from the board; nothing starts them (no init
  scripts under `BR2_INIT_NONE`). nfs-utils selects a system libsqlite3.
* The usbip userland is **not** included: Buildroot's package depends on
  udev, which this system does not ship. The `usbip-core`/`usbip-host`
  modules are present; `usbipd` runs from a privileged container.

## v0.5.0

podman replaces balenaEngine as the container engine, and nftables replaces
iptables. Build-proof only so far: the device gates (migration from
balenaEngine, A/B revert, reboots) run with the Vagus release that switches
to podman.

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

## v0.4.0

Kernel 7.2, and with it the onboard radio driver, fastrpc, balenaEngine and
`nerves_system_br`. Validated on hardware 2026-10-12 on a UFS and an NVMe
board: OTA from 0.3.3, A/B revert, ethernet, watchdog, `fastrpc_test` 3/3,
Venus decode, `aplay` without error (output not listened to), USB3, WiFi and
BLE scan, PoE fan, and the container stack. Not re-run: WiFi association, BLE
advertising/GATT, and the QAIRT host recipe.

* **Kernel 7.1.4 → 7.2.10.** 7.1 reached end of life with 7.1.13
  (2026-09-02); 7.2 is the only maintained 7.x line.
  `linux-7.1.defconfig` is renamed `linux-7.2.defconfig`. The four carried
  patches apply at `--fuzz=0` with no offset, and none of their changes is
  in mainline v7.2.10.
* 55 symbols that 7.2 turns on by default are disabled: 48 TLMM pinctrl
  drivers for other Qualcomm SoCs (≈ 1.45 MB resident), an IPQ clock
  controller, two X1P42100 clock modules, a Cadence USB PCI module, two
  errata for cores this SoC lacks, and the Alibaba NIC vendor gate. No
  devicetree node on this board binds to any of them.
* `CONFIG_VIDEO_QCOM_IRIS` is disabled so the Venus driver keeps the codec: 7.2
  would otherwise hand the `qcom,sc7280-venus` node to iris, which does not
  probe here.
* The Venus nodes come up in the other order than on 7.1.4: the decoder is
  `/dev/video1` and the encoder `/dev/video0`. The numbering follows module
  load order; select a node by `/sys/class/video4linux/*/name`
  (`qcom-venus-decoder` / `qcom-venus-encoder`).
* `aic8800` + `aic8800-firmware` → radxa-pkg/aic8800 `d13d079` (deb
  `5.0+git20260123.5f7be68d-9`). The previous pin (`6e07604`, deb `-7`) has
  no build support past 7.1. 26 of the 28 debian patches are replayed; the
  same two CRLF-blocked patches stay skipped.
* **fastrpc v1.0.4 → v1.0.8** (a use-after-free in session teardown, missing
  unlocks on failure paths, input validation in the remote API entry
  points). **The daemons (`adsprpcd`, `cdsprpcd`, `sdsprpcd`, `gdsprpcd`)
  move from `/usr/bin` to `/usr/sbin`.** Both are on erlinit's default
  `PATH`, so bare names still resolve; anything that spawns them by
  absolute path has to follow. New: `/usr/bin/fastrpc-healthcheck`.
  Upstream now also installs `/lib/udev/rules.d/60-fastrpc.rules` and
  `/usr/lib/sysusers.d/fastrpc.conf`; both are inert under Nerves, and
  where udev does run the overlay's `99-qcom-ai.rules` sorts later, so its
  `MODE="0666"` is still the one that applies.
* balenaEngine `d7af640` → `338143c` (still v25.0.14; the commit
  meta-balena pins). The one source change: volume options are saved with an
  atomic write, so a power cut can no longer leave a truncated `opts.json`
  that stops the daemon starting.
* `nerves_system_br` 1.34.0 → 1.34.4: Buildroot 2026.05 → 2026.05.2 and
  Erlang/OTP 29.0.2 → 29.0.6, both security updates. The Buildroot move
  includes wpa_supplicant 2.11 → 2.12, OpenSSL 3.6.2 → 3.6.3, expat 2.8.1
  → 2.8.3 and GLib 2.86.5 → 2.88.3. GRUB (2.12), fwup (1.16.0) and the
  toolchain (15.3.0) are unchanged.
* Patch `0003` header corrected: commit `3929d18a1aaa` is from Radxa's
  kernel tree, not mainline (the v0.3.0 entry below calls it upstream).

## v0.3.3

Repo tag v0.3.4.

Kernel memory tuning, shared across all 11 targets via a new
`shared/linux-memory.config` fragment, plus a THP fix measured on this board.
Kernel-config change on a previously-working board — the merged `.config` is
audited (every fragment symbol grepped for both an rpi 6.18 build and this
7.1 build) and the existing capability smoke set is re-run on device before
the tag. Closes #18 (kernel half).

* **THP `always` → `madvise`: measured 536 MB of a 974 MB BEAM (`beam.smp`)
  RSS was AnonHugePages padding.** A live switch to madvise + add-on restart
  took AnonHugePages to 0. `madvise` rather than `never` because ERTS never
  madvises hugepages on arm (otp PR #8702), so BEAM gets zero huge pages
  while legitimate madvise callers still get them.
* **`CONFIG_PANIC_TIMEOUT` was unset here, i.e. 0: a kernel panic hung
  forever.** The shared fragment sets 10 (matches the rpi trees; HAOS uses
  5), so a panicked board now reboots on its own.
* New `shared/linux-memory.config` fragment (synced to all 11 targets)
  builds in `SWAP`, `PSI` (+ `/proc/pressure/*` live), `LRU_GEN` +
  `LRU_GEN_ENABLED` (MGLRU on by default, with a runtime kill switch at
  `/sys/kernel/mm/lru_gen/enabled`), `ZSMALLOC`, `ZRAM` + LZ4 backend, and
  `ZSWAP` + LZ4 default compressor. `ZSWAP_DEFAULT_ON` is deliberately left
  off: which backend is active is a runtime decision — the upcoming
  `Vagus.Host.Swap` (vagus 0.9.0) picks zram on SD/eMMC boards or a `/data`
  swapfile + zswap on UFS/NVMe boards, and zswap in front of zram would
  double-compress. Until that release ships, this is a build-only change —
  nothing activates swap, and behaviour is otherwise unchanged apart from
  THP, `PANIC_TIMEOUT`, squashfs decompression, and `dirty_bytes`.
  `BLK_DEV_RAM` is off (Nerves boots squashfs directly; the 16 default
  ramdisk devices were dead weight).
* Dead-symbol prune on this defconfig: `NUMA`/`NUMA_BALANCING`,
  `MEMORY_HOTPLUG`/`MEMORY_HOTREMOVE`, `HUGETLBFS`/`CGROUP_HUGETLB`,
  `VIRTIO_BALLOON`, and `KALLSYMS_ALL` removed — single-node SoC, bare
  metal, no hugetlbfs consumer. Audited and kept: `PERF_EVENTS` (implied by
  `CONFIG_PROFILING=y` already in this defconfig; `CGROUP_PERF` and the BPF
  tracing paths hang off it, and it costs nothing at rest) and `KSM`
  (inert — nothing on this board madvises `MERGEABLE`).
* `SQUASHFS_FILE_DIRECT` + `SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU` added — the unset
  default (`FILE_CACHE` + `DECOMP_SINGLE`) serialises rootfs decompression
  on one core; the rpi and HAOS kernels both build direct + per-CPU.
* `shared/sysctl.conf` is now the canonical overlay file, synced into every
  target's `rootfs_overlay/etc/` (`make sync`/`make check` cover it, so the
  8 previously-dormant targets get it for the first time). Adds
  `vm.dirty_background_bytes = 16 MiB` and `vm.dirty_bytes = 64 MiB` in
  place of the 10/20 % ratio defaults: on this board's RAM the ratio lets
  ~2.4 GB of dirty pages pile up before a flush stalls everything; on a
  1 GB Pi the same ratio risks SD-card write storms. `vm.swappiness` is
  removed — it depends on the backing (150 on zram boards, 10 on
  swapfile+zswap boards) and is now set at runtime by `Vagus.Host.Swap`.

## v0.3.2

Repo tag v0.3.3.

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

This is also the first tagged release of this target (`VERSION` 0.1.0 below
was never tagged), so it is where the work that landed between the initial
target and the container runtime first shipped:

* Onboard AIC8800D80 WiFi + Bluetooth: `package/aic8800` (`aic_load_fw`,
  `aic8800_fdrv` → `wlan0`, `aic_btusb` → `hci0`) and
  `package/aic8800-firmware`, both at radxa-pkg/aic8800 `6e07604`, with
  Radxa's debian patch series replayed and `CONFIG_BLUEDROID` flipped to
  BlueZ. With it: `wireless-regdb`, the rpi3_64 `wpa_supplicant` option
  set, `CONFIG_IP_ADVANCED_ROUTER` + `CONFIG_IP_MULTIPLE_TABLES`
  (`vintage_net`'s RouteManager requires policy routing), and a faster LE
  advertising interval in `/etc/bluetooth/main.conf`.
* USB3: `patches/linux/0001` enables the SuperSpeed controller and the
  USB-A SS lanes.
* `alsa-utils` (`aplay`/`amixer`) for headphone-jack playback.
* `expand-data` fwup op + `resize2fs`, to grow `/data` after an EDL flash.
* Firmware: `rtl_nic/rtl8168h-2.fw` and the board audio topology at the
  `qcom/qcs6490/` request path.

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
