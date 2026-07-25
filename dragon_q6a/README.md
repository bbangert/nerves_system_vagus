# Radxa Dragon Q6A (QCS6490)

This is the Nerves System configuration for the Radxa Dragon Q6A — a
general-purpose aarch64 target with a first-class **on-device AI
foundation** (Hexagon NPU via fastrpc, Venus video codec).

| Feature        | Description                                     |
| -------------- | ----------------------------------------------- |
| CPU            | QCS6490 (4x Cortex-A78 + 4x Cortex-A55)         |
| Memory         | 4/8/16 GB LPDDR4x                               |
| Storage        | NVMe (M.2) — UFS variant planned (see below)    |
| Ethernet       | RTL8125 2.5 GbE (r8169 driver, `eth0`)          |
| NPU/DSP        | Hexagon v68 CDSP (~12 TOPS) via fastrpc         |
| Video          | Venus V4L2 M2M (`/dev/video0` dec, `1` enc)     |
| GPU            | Adreno 643 (drm/msm module; userspace not shipped) |
| Serial console | `ttyMSM0` (GENI debug UART, 115200n8)           |
| Boot           | EDK2 UEFI (SPI NOR) → GRUB2 arm64-efi → A/B     |
| Watchdog       | qcom_wdt + nerves_heart                         |

## Boot chain and A/B updates

EDK2 UEFI on the board's SPI NOR loads `\EFI\BOOT\BOOTAA64.EFI` (GRUB2,
arm64-efi) from the ESP. GRUB reads `grubenv` for the active slot and boots
the kernel `Image` **from inside the active squashfs slot** (`squash4`
module), so kernel, devicetree, firmware blobs, and rootfs update
atomically per slot. fwup's uboot-env block carries the Nerves metadata;
`upgrade.a`/`upgrade.b` flip both stores.

**The mainline DTB is loaded explicitly by GRUB** (`fdt` module,
`devicetree` command) from the active slot. The EDK2-provided devicetree is
Radxa's 6.18-era tree whose CDSP reserved-memory layout
(`cdsp_mem@8e000000`) mismatches mainline 7.1's (`cdsp_mem@87000000`) —
with the firmware DT the CDSP boots but every fastrpc invoke fails. If the
DTB load fails, grub.cfg falls back to the firmware DT (system boots;
DSP offload degraded). Memory and XBL reservations always arrive via the
EFI memory map, so bypassing EDK2's DT fixups is safe on this board
(device-verified).

Disk layout (GPT, 512-byte sectors, NVMe):

```
p1  config   FAT16    16 MiB   empty (RadxaOS-shaped placeholder / provisioning store)
p2  efi      FAT32    64 MiB   BOOTAA64.EFI, grub.cfg, grubenv
p3  rootfs-a squashfs 512 MiB  /boot/Image + DTB inside
p4  rootfs-b squashfs 512 MiB
p5  data     ext4     512 MiB+ /data (expand=true)
```

> **Note (EDL flashing):** fwup's `expand=true` only applies when fwup
> writes the block device directly. EDL writes a pre-generated image
> verbatim, so `/data` starts at 512 MiB with the backup GPT at the
> image-tail position. Grow it to the full disk with the one-shot
> `expand-data` op (rewrites the GPT sized to the real device, then the
> ext4 is grown online):
>
> ```sh
> fwup -t expand-data -d /dev/rootdisk0 /usr/share/fwup/ops.fw
> reboot   # kernel rereads the partition table
> resize2fs /dev/rootdisk0p5
> ```

## Flashing

See [docs/dragon-q6a-flashing.md](../docs/dragon-q6a-flashing.md) for the
EDL runbook (qcserial blacklist, EDL entry sequence, edl-ng invocation,
recovery paths). The SPI-NOR EDK2 firmware is a user-flashed prerequisite.

## AI foundation contract

What this system guarantees to applications (all device-validated):

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` present; DMA-BUF system
  heap at `/dev/dma_heap/system`; Venus at `/dev/video0` (dec) and
  `/dev/video1` (enc).
- **Firmware** (`/lib/firmware/qcom/...`): matched CDSP set (c3 line, see
  VERSIONS), board ADSP set with `.jsn` fastrpc domain descriptors, Adreno
  a660 GMU/SQE/zap, Venus `vpu-2.0/venus.mbn`, GENI `qupv3fw.elf` — all
  from a single upstream linux-firmware release. The CDSP image is
  installed at BOTH request paths (mainline DTS asks
  `qcom/qcs6490/cdsp.mbn`; the firmware DT asks
  `qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn`).
- **DSP-side libraries**: `/usr/lib/dsp/cdsp` and `/usr/lib/dsp/adsp`
  (per-domain dirs — the sysmon skel filenames collide between sets).
  fastrpc's built-in search path is patched to include both, `cdsp/`
  first; ADSP-domain processes should set `ADSP_LIBRARY_PATH` explicitly.
- **fastrpc userspace**: `libcdsprpc.so`/`libadsprpc.so`, the
  `adsprpcd`/`cdsprpcd` daemons, and `fastrpc_test` (+ v68 test skels).
  `fastrpc_test -a v68` passes 3/3 out of the box.
- **`libstdc++` in the target rootfs** — required by QAIRT.
- **QAIRT is NOT shipped.** Applications provision the QAIRT runtime
  bundle (and models) to `/data` themselves; the HTP delegate's
  `cache_dir` should also live on `/data` to avoid recompiling graphs
  (device-proven: 2.2 s compile run vs 221 ms warm start; note the cache
  directory must EXIST or `--cache_dir` silently no-ops). The SDK's
  prebuilt `qtld-net-run` (TFLite statically linked) runs .tflite models
  through the QNN HTP delegate with no TFLite build of your own.
- **udev rules** at `/etc/udev/rules.d/99-qcom-ai.rules` are the
  documented device-permission contract; they are inert on Nerves itself
  (no udev; the app runs as root) but apply in containers/dev images.

## DSP daemon supervision (deliberate non-decision)

The system SHIPS the fastrpc daemons (`adsprpcd`, `cdsprpcd`) but does NOT
start or supervise them — there is no init system on Nerves. Supervision is
app-level: start them from your OTP application (e.g. with
[MuonTrap](https://hex.pm/packages/muontrap)) so restarts, backoff, and
shutdown ride the app's supervision tree. Note the daemons serve root-PD
exception logging and remote file access; plain `fastrpc_test`-style
unsigned-PD offload works without them.

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

## Audio playback (validated recipe)

The mixer powers up with the entire headphone path disconnected/muted.
The validated `amixer -c 0 cset` sequence (runtime state — apply from the
application at boot; `alsactl` is not shipped):

```sh
# frontend -> codec-DMA backend
name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1
# rx-macro: RX0/RX1 from AIF1, interpolators CONNECTED (default is ZERO!)
name='RX_MACRO RX0 MUX' AIF1_PB          name='RX_MACRO RX1 MUX' AIF1_PB
name='RX INT0_1 MIX1 INP0' RX0           name='RX INT1_1 MIX1 INP0' RX1
name='RX INT0_1 INTERP' 'RX INT0_1 MIX1' name='RX INT1_1 INTERP' 'RX INT1_1 MIX1'
name='RX INT0 DEM MUX' CLSH_DSM_OUT      name='RX INT1 DEM MUX' CLSH_DSM_OUT
name='RX_COMP1 Switch' 1                 name='RX_COMP2 Switch' 1
# wcd938x: DAC/PA path + Class-H mode (default CLS_H_INVALID = silence!)
name='HPHL_RDAC Switch' 1  name='HPHR_RDAC Switch' 1
name='HPHL Switch' 1       name='HPHR Switch' 1
name='HPHL_COMP Switch' 1  name='HPHR_COMP Switch' 1
name='RX HPH Mode' CLS_H_LOHIFI
# volumes (DSP stream volume defaults low; digital 84 = 0 dB)
name='stream0.vol_ctrl0 MultiMedia1 Playback Volu' 100%
name='RX_RX0 Digital Volume' 84  name='RX_RX1 Digital Volume' 84
name='HPHL Volume' 20            name='HPHR Volume' 20
```

Then `aplay -D hw:0,0 file.wav` (48 kHz S16_LE stereo; use `plughw` for
other formats). The two silent traps: `RX INT*_1 INTERP` defaults to
`ZERO` and `RX HPH Mode` defaults to `CLS_H_INVALID` — each alone mutes
program audio while still passing transient clicks.

## VERSIONS (validated stack)

Every row below was validated together on hardware on 2026-07-24
(boot → ethernet → A/B OTA + revert → watchdog → `fastrpc_test` 3/3).

| Component | Version | Notes |
|---|---|---|
| SPI-NOR firmware | EDK2, EFI v2.7 by Qualcomm | Radxa flat_build; provides the (unused-by-default) firmware DT |
| Kernel | mainline **7.1.4** + 1 DTS patch (`patches/linux/`) | Q6A DTS in-tree; patch enables the SuperSpeed controller (USB-only trim of Armbian's USB3/HDMI patch) |
| Devicetree | in-tree `qcom/qcs6490-radxa-dragon-q6a.dtb` (7.1.4) | loaded by GRUB from the active slot |
| GRUB | 2.12 (Buildroot), arm64-efi | builtin modules incl. `squash4`, `loadenv`, `fdt` |
| Buildroot | 2026.05 via nerves_system_br 1.34.0 | |
| Toolchain | `aarch64-nerves-linux-gnu` 15.3.0 (glibc) | `-march=armv8.2-a` (no a78.a55 `-mcpu` pair in GCC) |
| linux-firmware | 20260410 (Buildroot pin) | single source for all qcom blobs |
| CDSP firmware | `qcom/qcm6490/cdsp.mbn` = **CDSP.HT.2.5.c3-00134-KODIAK-1** | matched pair with shells below |
| CDSP shells/skels | hexagon-dsp-binaries `qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1` @ 2113cae | → `/usr/lib/dsp/cdsp` |
| ADSP firmware | `radxa/dragon-q6a/adsp.mbn` = **ADSP.HT.5.5.c9-00028-KODIAK-2** | + `adspr.jsn`/`adspua.jsn` |
| ADSP shells | hexagon-dsp-binaries `qcs6490/radxa/dragon-q6a/ADSP.HT.5.5.c9-00028-KODIAK-2` | → `/usr/lib/dsp/adsp` |
| fastrpc userspace | v1.0.4 (qualcomm/fastrpc) | search path patched to `/usr/lib/dsp/{cdsp,adsp}` |
| Venus firmware | `qcom/vpu-2.0/venus.mbn` (= `vpu/vpu20_p1.mbn`) | `test_src/venus_dec_smoke` decodes 30/30 frames on hardware |
| QAIRT | — not shipped (user-provisioned to `/data/qairt`); **2.48.40.260702 validated on this system** | HTP validator unit test PASS; yolov11 w8a8 via `qtld-net-run`: ≤7.4 ms/inference (I/O-inclusive), CPU 11%/8 cores, 221 ms warm start via delegate cache |

**Matched-pair rule:** the CDSP firmware and the fastrpc shells must carry
the same `QC_IMAGE_VERSION_STRING` (`strings cdsp.mbn | grep QC_IMAGE`).
A mismatch fails with fastrpc error `0x80000600` and no kernel log. The
board-specific c4-00004 CDSP pair is a known dead-end on mainline kernels
(PD creates, all invokes fail) — do not swap it back without new evidence.

## Known-out-of-scope / open items

- **USB: both controllers up, SuperSpeed registered** (device-proven):
  the carried DTS patch enables the SS-capable controller (`a600000`,
  QMP phy RX1/TX1 → USB-A port) — a 5000 Mbps root hub registers
  alongside the two 480 Mbps buses; the onboard hub + AIC8800 module +
  BT dongle live on the USB2 tree. Enumerating an actual 5 Gbps device
  is the one leg not yet exercised. The early boot line
  `dwc3-qcom: failed to register DWC3 Core` is a transient from before
  the HS PHY probes; the driver retries and binds.
- **GPU/display**: drm/msm ships as a module but the Adreno SMMU defers
  (-110) and no GPU userspace (mesa) is shipped.
- **Audio playback: device-proven** through the headphone jack (WCD938x)
  with `aplay` — see the mixer recipe below. Capture is unvalidated.
  Cosmetic dmesg: soundwire `cgcr reset` + `din/dout-ports mismatch`
  lines, and an occasional MBHC `Impedance detect ramp error` on
  unusual jack loads.
- **WiFi/BT (onboard AIC8800)**: out-of-tree driver, deliberately not
  shipped (module enumerates on USB but stays driverless). **USB BT
  dongles are device-proven**: a TP-Link UB500 (RTL8761BU) enumerated,
  btusb loaded the shipped `rtl_bt` firmware, and the adapter powered on
  and was discoverable over the air via bluetoothd/D-Bus. Note for app
  authors: BlueZ cancels discovery when the requesting D-Bus client
  disconnects, so inbound scanning needs a persistent client (e.g. the
  `bluez` hex library), not one-shot `dbus-send` calls.
- **UFS variant** (`_4096` image, 4096-byte sectors): planned, not started.
