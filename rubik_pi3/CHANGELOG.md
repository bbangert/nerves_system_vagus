# Changelog

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
* `SQUASHFS_FILE_DIRECT` + `SQUASHFS_DECOMP_MULTI_PERCPU` added — the unset
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
