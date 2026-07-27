# Changelog

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
