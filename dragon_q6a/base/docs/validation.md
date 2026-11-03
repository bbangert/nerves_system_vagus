# Validation record

The hardware evidence behind the README's Hardware support table. Every
proof below was taken while this system was the `dragon_q6a` target of
bbangert/nerves_system_vagus, with that repo's product layer (BlueZ, the
container stack) on top, on the nerves_system_br 1.34.4 / Buildroot 2026.05.2
/ toolchain 15.3.0 line or earlier. "This system version" below means that
target's v0.4.0 (2026-10-12). The current nerves_system_br 1.35.3 /
Buildroot 2026.08.1 / OTP 29.1.2 / toolchain 15.3.1 line is build-proof only
until it is re-gated.

## Validated stack

The table is carried over verbatim; the podman row describes product-layer
packages that are not part of this system.

The original rows below were validated together on hardware on 2026-07-24
(boot → ethernet → A/B OTA + revert → watchdog → `fastrpc_test` 3/3).
Components added or moved since carry their own proof date in the Notes
column; the 2026-10-12 proofs ran on this system version, on one board
booting from NVMe and one from a UFS module.
Where a note says "last hardware-validated on …", the capability it names
ships, or rides on, a newer version than the one its proof covers.

| Component | Version | Notes |
|---|---|---|
| SPI-NOR firmware | EDK2, EFI v2.7 by Qualcomm | Radxa flat_build; provides the (unused-by-default) firmware DT |
| Kernel | mainline **7.2.10** + 4 patches (`patches/linux/`) | Q6A DTS in-tree. `0001` enables USB3 (USB-only trim of Armbian's USB3/HDMI patch); `0002` enables the UFS controller + PHY (Armbian's qcs6490 series); `0003` is the qmp-ufs HS-G4 PHY init table from Radxa's kernel tree, absent from mainline; `0004` is the PoE+ HAT fan, authored here. Hardware-validated 2026-10-12: OTA from 0.3.3 and boot on an NVMe and a UFS board, A/B revert on the UFS board |
| Devicetree | in-tree `qcom/qcs6490-radxa-dragon-q6a.dtb` (7.2.10) + the three DTS patches above | loaded by GRUB from the active slot; hardware-validated 2026-10-12 with the kernel |
| GRUB | 2.12 (Buildroot), arm64-efi | builtin modules incl. `squash4`, `loadenv`, `fdt`, `regexp` (grub.cfg derives the boot disk from `$root`) |
| Buildroot | 2026.05.2 via nerves_system_br 1.34.4 | Erlang/OTP 29.0.6; hardware-validated 2026-10-12 (OTA from 0.3.3, boot, container stack) |
| Toolchain | `aarch64-nerves-linux-gnu` 15.3.0 (glibc) | `-march=armv8.2-a` (no a78.a55 `-mcpu` pair in GCC) |
| linux-firmware | 20260410 (Buildroot pin) | single source for all qcom blobs |
| CDSP firmware | `qcom/qcm6490/cdsp.mbn` = **CDSP.HT.2.5.c3-00134-KODIAK-1** | matched pair with shells below |
| CDSP shells/skels | hexagon-dsp-binaries `qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1` @ 2113cae | → `/usr/lib/dsp/cdsp` |
| ADSP firmware | `radxa/dragon-q6a/adsp.mbn` = **ADSP.HT.5.5.c9-00028-KODIAK-2** | + `adspr.jsn`/`adspua.jsn` |
| ADSP shells | hexagon-dsp-binaries `qcs6490/radxa/dragon-q6a/ADSP.HT.5.5.c9-00028-KODIAK-2` | → `/usr/lib/dsp/adsp` |
| fastrpc userspace | v1.0.8 (qualcomm/fastrpc) | search path patched to `/usr/lib/dsp/{cdsp,adsp}`; `fastrpc_test -a v68` 3/3, 2026-10-12 |
| Venus firmware | `qcom/vpu-2.0/venus.mbn` (= `vpu/vpu20_p1.mbn`) | `test_src/venus_dec_smoke`: 30/30 frames, 2026-10-12 on kernel 7.2.10 (decoder node; see the node-order note in the AI foundation contract) |
| QAIRT | — not shipped (user-provisioned to `/data/qairt`); **2.48.40.260702 validated on this system** | HTP validator unit test PASS; yolov11 w8a8 via `qtld-net-run`: ≤7.4 ms/inference (I/O-inclusive), CPU 11%/8 cores, 221 ms warm start via delegate cache — this host-side recipe last hardware-validated on kernel 7.1.4 + fastrpc v1.0.4. QNN inference on the Hexagon DSP from an app container: proven 2026-10-12 on kernel 7.2.10 |
| AIC8800 driver | radxa-pkg/aic8800 @ `d13d079` (deb `5.0+git20260123.5f7be68d-9`) | `aic_load_fw` + `aic8800_fdrv` (→ `wlan0`) + `aic_btusb` (→ `hci0`); debian patch series replayed (26 of 28), `CONFIG_BLUEDROID` flipped to BlueZ. Module + firmware load, `wlan0` scan (2.4 and 5 GHz), `hci0` + BLE scan: 2026-10-12. Association, WPA3, BLE advertising, GATT: last hardware-validated on `6e07604` (deb `-7`), 2026-07-25/26 |
| AIC8800 firmware | same commit, `fw/aic8800D80/` | installed to `/lib/firmware/aic8800D80/`; proprietary Aicsemi blobs, byte-identical to `6e07604`'s (hardware-validated 2026-07-25/26 with that pin's driver; the driver row covers the new one) |
| wpa_supplicant | 2.12 (Buildroot pin), rpi3_64 option set (incl. `CTRL_IFACE`) | vintage_net_wifi's required control socket at `/usr/sbin/wpa_supplicant`; start-up and scan proven 2026-10-12; association last hardware-validated on 2.11, 2026-07-25/26 |
| wireless-regdb | Buildroot pin | mandatory — this kernel sets `CFG80211_REQUIRE_SIGNED_REGDB=y` |
| podman | 6.1.4, with netavark 2.1.0, crun 1.30.1, conmon 2.1.8, catatonit 0.2.1 | `package/vagus-{podman,netavark,crun}` (synced from `shared/package/`); ran Core and the bench apps, driven by hand, in a throwaway build, 2026-10-13; not yet device-proven as shipped |

## Matched-pair rule

**Matched-pair rule:** the CDSP firmware and the fastrpc shells must carry
the same `QC_IMAGE_VERSION_STRING` (`strings cdsp.mbn | grep QC_IMAGE`).
A mismatch fails with fastrpc error `0x80000600` and no kernel log. The
board-specific c4-00004 CDSP pair is a known dead-end on mainline kernels
(PD creates, all invokes fail) — do not swap it back without new evidence.

## Other recorded proofs

From that target's README and CHANGELOG:

- **2026-10-12 gate (v0.4.0), on an NVMe and a UFS board:** OTA from 0.3.3,
  A/B revert, ethernet, watchdog, `fastrpc_test` 3/3, Venus decode, `aplay`
  without error (output not listened to), USB3, WiFi and BLE scan, PoE fan,
  and the container stack. Not re-run then: WiFi association, BLE
  advertising/GATT, and the QAIRT host recipe.
- **UFS module (2026-08-02):** 128 GB module provisioned, EDL-flashed,
  booted, ethernet, `/data` at full module size on first boot, A/B OTA
  cycle. Boot order with NVMe and UFS both fitted is unverified.
- **USB:** both controllers up and a 5000 Mbps root hub registers beside the
  two 480 Mbps buses; enumerating an actual 5 Gbps device is not yet
  exercised. The onboard hub, the AIC8800 module and BT dongles sit on the
  USB2 tree.
- **GPU render node (v0.6.1):** `/dev/dri/renderD128` appears unattended
  and the a660 SQE/GMU firmware loads on first open. No display (mdss is
  disabled in the DTS) and no Mesa.
- **Audio:** headphone playback through the WCD938x with the recipe in
  [audio.md](audio.md); capture unvalidated.
- **USB BT dongle:** a TP-Link UB500 (RTL8761BU) enumerated, btusb loaded the
  shipped `rtl_bt` firmware, and the adapter powered on and was
  discoverable over the air via bluetoothd/D-Bus (BlueZ from the product
  layer).
- **Onboard WiFi/BT:** see the status table in [wifi-bt.md](wifi-bt.md).
