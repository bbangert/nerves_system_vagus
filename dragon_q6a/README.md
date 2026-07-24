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
  `cache_dir` should also live on `/data` to avoid recompiling graphs.
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

## VERSIONS (validated stack)

Every row below was validated together on hardware on 2026-07-24
(boot → ethernet → A/B OTA + revert → watchdog → `fastrpc_test` 3/3).

| Component | Version | Notes |
|---|---|---|
| SPI-NOR firmware | EDK2, EFI v2.7 by Qualcomm | Radxa flat_build; provides the (unused-by-default) firmware DT |
| Kernel | mainline **7.1.4** (kernel.org) | Q6A DTS in-tree; config derived from arm64 defconfig |
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
| Venus firmware | `qcom/vpu-2.0/venus.mbn` (= `vpu/vpu20_p1.mbn`) | `/dev/video0`+`1` probe verified |
| QAIRT | — not shipped; 2.45.40.260406 validated on this board under RadxaOS (q6a_ai reference) | HTP smoke on this system pending (plan gate 3.3) |

**Matched-pair rule:** the CDSP firmware and the fastrpc shells must carry
the same `QC_IMAGE_VERSION_STRING` (`strings cdsp.mbn | grep QC_IMAGE`).
A mismatch fails with fastrpc error `0x80000600` and no kernel log. The
board-specific c4-00004 CDSP pair is a known dead-end on mainline kernels
(PD creates, all invokes fail) — do not swap it back without new evidence.

## Known-out-of-scope / open items

- **USB non-functional**: the stock 7.1 DTS lacks the USB3 enables Armbian
  patches in (`dwc3-qcom failed to register DWC3 Core`).
- **GPU/display**: drm/msm ships as a module but the Adreno SMMU defers
  (-110) and no GPU userspace (mesa) is shipped.
- **Audio**: mainline-DTB audio nodes probe but the board topology blob
  (`QCS6490-Radxa-Dragon-Q6A-tplg.bin`) is not shipped.
- **WiFi/BT (onboard AIC8800)**: out-of-tree driver, not shipped. USB BT
  dongles work (BlueZ + Realtek blobs included).
- `/data` expansion under EDL flashing (see layout note above).
- **UFS variant** (`_4096` image, 4096-byte sectors): planned, not started.
