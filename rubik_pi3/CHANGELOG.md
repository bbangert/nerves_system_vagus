# Changelog

## Unreleased

Not yet tagged. Follows `dragon_q6a`: podman replaces balenaEngine as the
container engine, and nftables replaces iptables. Build-proof only: this
target has never booted on hardware.

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

## v0.2.0

Repo tag v0.4.0. Follows `dragon_q6a` to kernel 7.2, with the same fastrpc,
balenaEngine and `nerves_system_br` moves. Build-proof only: this target
has never booted on hardware.

* **Kernel 7.1.4 → 7.2.10.** 7.1 reached end of life with 7.1.13
  (2026-09-02); 7.2 is the only maintained 7.x line.
  `linux-7.1.defconfig` is renamed `linux-7.2.defconfig`. The one carried
  patch (`0003`, the qmp-ufs HS-G4 PHY init table) is unchanged below its
  header; the header now attributes commit `3929d18a1aaa` to Radxa's
  kernel tree, not mainline.
* 55 symbols that 7.2 turns on by default are disabled: 48 TLMM pinctrl
  drivers for other Qualcomm SoCs (≈ 1.45 MB resident), an IPQ clock
  controller, two X1P42100 clock modules, a Cadence USB PCI module, two
  errata for cores this SoC lacks, and the Alibaba NIC vendor gate. No
  devicetree node on this board binds to any of them.
* `CONFIG_VIDEO_QCOM_IRIS` is disabled so the Venus driver keeps the codec: 7.2
  would otherwise hand the `qcom,sc7280-venus` node to iris, which does not
  probe here.
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

## v0.1.1

Kernel memory tuning, shared with `dragon_q6a` (this target's 7.1 defconfig
tracks it symbol-for-symbol). This target has never booted on hardware, so
this is build-gated only here — device proof of the shared changes comes
from `dragon_q6a`. Closes #18 (kernel half).

* **THP `always` → `madvise`**, same fix `dragon_q6a` measured (536 MB of a
  974 MB BEAM RSS was AnonHugePages padding under `always`). `madvise`
  rather than `never` because ERTS never madvises hugepages on arm (otp PR
  #8702), so BEAM gets zero huge pages while legitimate madvise callers
  still get them.
* **`CONFIG_PANIC_TIMEOUT` was unset here, i.e. 0: a kernel panic would hang
  forever.** The shared fragment sets 10 (matches the rpi trees; HAOS uses
  5).
* New `shared/linux-memory.config` fragment (synced to all 11 targets)
  builds in `SWAP`, `PSI`, `LRU_GEN` + `LRU_GEN_ENABLED` (MGLRU, with a
  runtime kill switch at `/sys/kernel/mm/lru_gen/enabled`), `ZSMALLOC`,
  `ZRAM` + LZ4 backend, and `ZSWAP` + LZ4 default compressor.
  `ZSWAP_DEFAULT_ON` stays off: which backend is active is a runtime
  decision for the upcoming `Vagus.Host.Swap` (vagus 0.9.0), and zswap in
  front of zram would double-compress. Nothing activates swap yet.
  `BLK_DEV_RAM` is off (Nerves boots squashfs directly).
* Dead-symbol prune on this defconfig, mirroring `dragon_q6a`:
  `NUMA`/`NUMA_BALANCING`, `MEMORY_HOTPLUG`/`MEMORY_HOTREMOVE`,
  `HUGETLBFS`/`CGROUP_HUGETLB`, `VIRTIO_BALLOON`, and `KALLSYMS_ALL`
  removed. `PERF_EVENTS` and `KSM` audited and kept (same reasoning as
  `dragon_q6a`: `PROFILING=y` implies the former and it costs nothing at
  rest; nothing madvises `MERGEABLE` so the latter is inert).
* `SQUASHFS_FILE_DIRECT` + `SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU` added — the unset
  default serialises rootfs decompression on one core.
* `shared/sysctl.conf` is now the canonical overlay file for this target
  too, adding `vm.dirty_background_bytes = 16 MiB` / `vm.dirty_bytes =
  64 MiB` in place of the ratio defaults; `vm.swappiness` is removed (set
  at runtime by `Vagus.Host.Swap` once it ships).

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
