# Changelog

Headings are this target's `VERSION`. Git tags are repo-wide and can differ;
an entry names its repo tag where it does.

## v0.1.2

* Ships D-Bus and BlueZ. Home Assistant installs apps by default that need
  the host system bus (Matter Server fails with `statfs /run/dbus: no such
  file or directory`), and users plug in USB Bluetooth dongles. `dbus-daemon`
  and `bluetoothd` are at the paths Vagus probes; Vagus starts them, so there
  are no init scripts.
* Adds the dongle firmware btusb loads: Realtek `rtl_bt`, Intel `ibt-*`,
  MediaTek MT7920/21/22/25 and Qualcomm 6174A. The kernel side was already
  in `linux-bluetooth.config`.
* No USB dongle has been tested on the board.

## v0.1.1

* Builds libnl. `nerves_pack` pulls `vintage_net_wifi` into every target's
  firmware, and its C port links libnl-genl-3.0, so a Vagus firmware for
  this radio-less board failed to build without it. No WiFi userspace is
  added.

## v0.1.0

First release of this target. The board support is nerves_system_ha_green
0.1.0 (vendored under `base/`): the Home Assistant Green's factory
first-stage loader stays untouched, our U-Boot is loaded from the SD card or
the eMMC, the Rockchip vendor kernel 6.1, A/B updates with automatic revert.
Its hardware validation record is `base/README.md`.

This layer adds what Vagus needs, the same container set as the other
boards:

* podman 6.1.4 + netavark + crun, conmon, catatonit, nftables and
  util-linux, with `cgroup2` and `configfs` mounted by erlinit. base mounts
  no cgroup v1 hierarchy, so no `cgroup_no_v1` cmdline flag is needed.
* The shared kernel fragments (`linux-bluetooth.config`,
  `linux-containers.config`, `linux-memory.config`) and `sysctl.conf`.

The Green has no WiFi or Bluetooth, so there is no BlueZ, D-Bus or
controller firmware.
