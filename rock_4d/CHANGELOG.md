# Changelog

Headings are this target's `VERSION`. Git tags are repo-wide and can differ;
an entry names its repo tag where it does.

## v0.1.0

First release of this target. The board support is nerves_system_rock_4d
v0.2.1 (vendored under `base/`): UFS boot with mainline U-Boot in SPI NOR,
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
