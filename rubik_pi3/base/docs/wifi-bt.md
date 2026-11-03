# WiFi and Bluetooth (onboard AP6256)

The onboard AMPAK AP6256 module (BCM43456-class, a CYW4345 C5 die) is
driven entirely by **mainline in-tree drivers**:

- **WiFi**: SDIO on `&sdhc_2`, `brcmfmac`/`brcmutil` kernel modules
  (`CONFIG_BRCMFMAC=m`, `CONFIG_BRCMFMAC_SDIO=y`). The FullMAC firmware
  is the vendor's own (`rubikpi-ai/rubikpi3-firmware`
  `fw_bcm43456c5_ag.bin`, 7.45.96.215, the same file as Thundercomm's stock
  image), installed as `brcmfmac43456-sdio.bin`. armbian's 7.45.96.0 never
  completed a join on this board. Board NVRAM is the vendor's (byte-identical
  to armbian's copy) and is installed under both the board-specific and
  generic filenames brcmfmac looks for. brcmfmac doesn't load a CLM blob for
  43456, so the firmware's built-in CLM applies.
- **Bluetooth**: a `brcm,bcm4345c5` serdev child of `&uart7`, driven by
  `hci_bcm`. The `BCM4345C5.hcd` patchram is taken from the board
  vendor's firmware repo specifically (not armbian's) — the vendor's
  version string (`Ampak AP6256 ... BT 5.2 [Version: 1081.1154]`) differs
  from armbian's generic Ampak CL1 patchram.
- `wireless-regdb` is mandatory (this kernel sets
  `CFG80211_REQUIRE_SIGNED_REGDB=y`).

**Note on driver choice:** the vendor OS for this board ships an
out-of-tree `bcmdhd` driver for the AP6256. This system instead uses the
mainline in-tree `brcmfmac`/`hci_bcm` path, which is DTS-correct (the
in-tree `qcs6490-thundercomm-rubikpi3.dts` describes the module exactly
this way). The one known gap is **WPA3-SAE**: the firmware's external SAE
("extsae" in its capability string) is bcmdhd's client-SAE flow, where the
host starts SAE on `WLC_E_JOIN_START` and drives it with the `assoc_mgr_cmd`
iovar. brcmfmac only implements Infineon's newer `EXT_AUTH_REQ`/`auth_status`
interface, so it doesn't advertise SAE and `wpa_supplicant` rejects SAE-only
networks ("Failed to select authenticated key management type"). Aliasing the
capability name isn't enough: the firmware then never starts SAE. A port of
the bcmdhd flow into brcmfmac_cyw was tried (2026-10-24) and got SAE itself
to complete, but the firmware then sends an association request with an
empty SSID element and the AP rejects it. No host-side change tried fixed
that, so WPA3-SAE is **not supported**. Use WPA2 (or WPA2/WPA3 transition)
networks.

## Bluetooth userspace

This system ships the kernel side and the patchram only: no BlueZ, no
D-Bus. The controller proof in [validation.md](validation.md) ran
`bluetoothd` and `dbus-daemon` from a product build, started by hand. An
application that wants Bluetooth adds those packages in its own system
layer (or talks HCI directly).

USB Bluetooth dongles that need Realtek firmware (`rtl_bt`, e.g. a TP-Link
UB500) are covered: `BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT` installs the
blobs.
