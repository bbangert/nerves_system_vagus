# Changelog

Headings are this target's `VERSION`. Git tags are repo-wide and can differ;
an entry names its repo tag where it does.

## v0.1.1

Repo tag v0.9.1. Moves base to nerves_system_rock_4d v0.2.4: the
application data partition (p5) is ext4 mounted at `/data`, matching the
other Vagus boards, instead of f2fs at `/root`. On f2fs the podman
swapfile could not be enabled and the provisioner's `resize2fs` failed.

Upgrading a board from v0.1.0 reformats p5 on the first boot: the ext4
mount fails on the old f2fs partition and nerves_runtime formats it, so
everything on it (Core's config, apps, SSH host keys) is lost.

## v0.1.0

First release of this target. The board support is nerves_system_rock_4d
v0.2.2 (vendored under `base/`): UFS boot with mainline U-Boot in SPI NOR,
the Rockchip vendor kernel 6.1.172, A/B updates with automatic revert. Its
hardware validation record is `base/README.md`.

This layer adds what Vagus needs, the same set as dragon_q6a minus the
hardware-debug NFS services (base has no knfsd):

* podman 6.1.4 + netavark + crun, conmon, catatonit, nftables and
  util-linux, with `cgroup2` and `configfs` mounted by erlinit. base mounts
  no cgroup v1 hierarchy, so no `cgroup_no_v1` cmdline flag is needed.
* BlueZ + D-Bus with the diagnostic tools, bluez-alsa, and the Realtek USB
  BT firmware set (base ships none).
* The shared kernel fragments (`linux-bluetooth.config`,
  `linux-containers.config`, `linux-memory.config`) and `sysctl.conf`.
