# Thundercomm Rubik Pi 3 (QCS6490)

This is the Nerves System configuration for the Thundercomm Rubik Pi 3 — a
general-purpose aarch64 target with a first-class **on-device AI
foundation** (Hexagon NPU via fastrpc, Venus video codec, Adreno GPU).

It is a **hard fork of this repo's `dragon_q6a` target**: same SoC
(QCS6490/Kodiak), same EDK2 UEFI + GRUB2 A/B boot chain, same AI-foundation
contract (fastrpc/CDSP/ADSP, DMA-BUF heap, Venus). The differences are
board-level — onboard WiFi/BT is an AP6256 module over mainline `brcmfmac`
instead of the Q6A's AIC8800, and ethernet is a USB AX88179B instead of an
onboard RTL8125. See "Device-proven status" below: **this target has not
yet been through device bring-up** — everything is built and config-reviewed
against the mainline kernel and datasheets, but unverified on real hardware
pending a later phase.

| Feature        | Description                                        |
| -------------- | --------------------------------------------------- |
| CPU            | QCS6490 (Kodiak), Kryo 670 (4x Cortex-A78 + 4x Cortex-A55) |
| GPU            | Adreno 643L (drm/msm module; userspace not shipped)  |
| NPU/DSP        | Hexagon v68 CDSP (~12 TOPS) via fastrpc              |
| Memory         | 8 GB LPDDR5                                          |
| Storage        | Onboard 128 GB UFS (4096-byte logical blocks, dual LUN) — primary boot disk; M.2 M-key NVMe (PCIe 3.0) present but boot/data-unused |
| Ethernet       | USB AX88179B gigabit (`ax88179_178a` driver), behind a UPD720201 USB3 controller |
| WiFi/BT        | AMPAK/Broadcom AP6256 (BCM43456-class) — WiFi over SDIO (`brcmfmac`), BT over UART7 serdev (`hci_bcm`) |
| USB            | 2x USB3-A (behind UPD720201) + USB-C                 |
| Video          | Venus V4L2 M2M (`/dev/video0` dec, `1` enc)          |
| Display        | HDMI out via an lt9611 bridge                        |
| Fan            | Native PWM fan with dts thermal cooling maps          |
| Expansion      | 40-pin header                                        |
| Serial console | `ttyMSM0` (GENI debug UART, 115200n8) — dts `serial0 = &uart5`, pending live verification |
| Boot           | EDK2 UEFI (UFS LUN4, Thundercomm build) → GRUB2 arm64-efi → A/B |
| Watchdog       | qcom_wdt + nerves_heart                              |
| Containers     | balenaEngine v25 + cgroup v2 — ported from the Q6A/rpi3_64 stack, not yet device-proven here |

## Device-proven status

None of these have been exercised on real Rubik Pi 3 hardware yet — bring-up
is a later phase. Listed here as the gate checklist that phase will work
through (mirroring the Q6A port's own bring-up gates):

| Gate | Status |
| --- | --- |
| Boot / serial console | pending |
| Dual-disk `rootdisk0` aliasing with NVMe populated | pending |
| WiFi STA (WPA2/WPA3) + AP mode | pending |
| BT / Improv provisioning | pending |
| balena containers | pending |
| Home Assistant stack | pending |
| Thermal fan control | pending |
| OTA A/B update cycle | pending |
| ADSP/CDSP fastrpc | pending |
| Venus video codec | pending |
| GPU render node | pending |

## Boot chain and A/B updates

PBL (SoC boot ROM) → XBL (UFS boot LUNs 1/2, A/B) → ... → EDK2 UEFI
(`uefi.elf`, Thundercomm's build, UFS LUN4) loads
`\EFI\BOOT\BOOTAA64.EFI` (GRUB2, arm64-efi) from the ESP on UFS LUN0.
Unlike the Q6A (whose XBL/EDK2 live on a separate SPI-NOR chip), this
board's entire stock boot chain — XBL, TZ, hypervisor, EDK2, DTB, and the
rest of the firmware image — lives on the onboard UFS itself, alongside
our GRUB/kernel/rootfs partitions on LUN0. GRUB reads `grubenv` for the
active slot and boots the kernel `Image` **from inside the active
squashfs slot** (`squash4` module), so kernel, devicetree, firmware
blobs, and rootfs update atomically per slot. fwup's uboot-env block
carries the Nerves metadata; `upgrade.a`/`upgrade.b` flip both stores.

**The mainline DTB is loaded explicitly by GRUB** (`fdt` module,
`devicetree` command) from the active slot rather than relying on the
firmware-provided DT. On the Q6A port (same SoC, Radxa's EDK2/6.18-era
firmware DT), the firmware DT's CDSP reserved-memory layout mismatched
mainline 7.1's, so the CDSP booted but every fastrpc invoke failed. The
same explicit-DTB fixup is carried here on the presumption that
Thundercomm's firmware DT has an analogous mismatch — **pending
verification on this board**. If the DTB load fails, `grub.cfg` falls back
to the firmware DT (system still boots; DSP offload degraded).

Expected serial console: `ttyMSM0` (GENI debug UART), matching the
mainline dts `serial0 = &uart5`, 115200n8 — pending live-board
verification.

## Flashing

Qualcomm EDL to the onboard UFS, **LUN0 only** — the stock boot chain in
LUNs 1/2/4 (see "Boot chain" above) is never touched, so this carries the
same no-bootloader-reflash property as the Q6A's SPI-NOR-based board, just
by a different mechanism (writing around the boot LUNs instead of a
separate chip). The 4Kn GPT-regeneration playbook (`tools/mk_ufs_image.py`)
is carried over from the Q6A port's UFS flashing flow.

### Sources / staging

The stock loader and rawprogram XMLs come from Thundercomm's public
FlatBuild flash package (no login, hosted on S3):
`https://thundercomm.s3.dualstack.ap-northeast-1.amazonaws.com/uploads/web/rubik-pi-3/20250905/FlatBuild_RUBIKPi-3_xx.xx_LE1.0.R.debug.FC.r001004.zip`
(2.85 GB). Only ~1 MB of it is actually needed: `ufs/prog_firehose_ddr.elf`
(sha256 `32ac27b0c28d4661bac18541dd503c5755fb4f11f08ba09c6c7d5c04ed67903b`,
1,019,904 bytes), plus optionally the stock `rawprogram0-6.xml`/
`patch0-6.xml` for reference or full-restore. These are proprietary
Thundercomm blobs — **not committed to this repo**; the sha256 above pins
the loader. A ranged-extraction script can pull individual files out of
the zip via HTTP range requests, so the full 2.85 GB archive never needs
to be downloaded.

Thundercomm's official flashing docs live in the `rubikpi-ai/documentation`
GitHub repo; their supported tool is Qualcomm Device Loader (QDL) 2.3.4
(Linux/macOS/Windows — Windows needs the WinUSB driver, and its CLI takes
no wildcards). This target instead uses `edl-ng` plus the Q6A port's
playbook for the custom LUN0-only write; QDL/FlatBuild remain the
stock-restore path (see "Why LUN0-only is safe" below).

### EDL entry

Documented by Thundercomm, and expected to match the Q6A's EDL behavior
(same SoC, same PBL/Sahara/Firehose flow):

- Cold entry: hold the **[EDL]** button, connect 12 V power while
  holding, then connect USB-C, wait ~3 s. The device enumerates as
  `05c6:9008` (QDL mode) — verify with `lsusb | grep 9008`.
- From a booted stock OS: `adb shell reboot edl`.

Host-side traps proven on the Q6A from the same workstation, expected to
carry over unchanged:

- The `qcserial` kernel module steals the one-shot Sahara HELLO —
  blacklist it (`modprobe -r qcserial` before entry, or a kernel-arg
  blacklist) ahead of every EDL session.
- A udev rule for `05c6:9008` with `MODE="0666"` avoids needing `sudo`.
- If `edl-ng` reports `mode: Unknown` with a `04…0D…01` Sahara packet,
  recover without power-cycling: run `bkerler/edl`'s `printgpt` once (it
  uploads the loader and, as a side effect, leaves Firehose live in DDR),
  then rerun `edl-ng`.

See `docs/dragon-q6a-flashing.md` for the full EDL runbook these traps
and the recovery path are drawn from, rather than re-documenting every
detail here.

### Flash procedure (LUN0 only)

> Steps below are the intended bench procedure, carried over from the
> Q6A port's UFS flow — **not yet device-proven on this board**.

1. Build the firmware and expand it to a raw 512-LBA image:

   ```sh
   mix firmware   # MIX_TARGET=rubik_pi3
   fwup -a -t complete -i vagus_platform.fw -d rubik_pi3.img
   # ~1.6 GiB
   ```

2. Probe the module's exact capacity with the board in EDL — the 4Kn
   backup-GPT placement and `/data` sizing both depend on the real byte
   count, not the nominal one:

   ```sh
   probe_ufs_capacity.sh
   # binary-search read-sector probes via edl-ng, carried from the Q6A
   # port. Nominal capacity is 128 GB (UFS 2.2), but the exact byte
   # count must come from the probe.
   ```

3. Regenerate the GPT for 4096-byte LBAs:

   ```sh
   tools/mk_ufs_image.py --input rubik_pi3.img \
       --disk-bytes <probed-bytes> --out rubik_pi3_ufs
   ```

   Emits `rubik_pi3_ufs.img` + `rubik_pi3_ufs-backup-gpt.bin`, and prints
   the two `edl-ng` write commands with the correct backup-GPT LBA.

4. Write both pieces to LUN0 (example uses nominal 128 GiB geometry —
   use the real LBAs the script in step 3 prints):

   ```sh
   edl-ng --loader prog_firehose_ddr.elf --memory ufs \
       write-sector 0 rubik_pi3_ufs.img --lun 0
   edl-ng --loader prog_firehose_ddr.elf --memory ufs \
       write-sector <backup-lba> rubik_pi3_ufs-backup-gpt.bin --lun 0
   ```

5. Exit EDL: unplug USB-C, power-cycle. First boot should show the GRUB
   A/B menu on serial (`ttyMSM0`, 115200n8), then erlinit/ssh.

### Why LUN0-only is safe / recovery

Writing LUN0 never touches the boot chain (LUNs 1/2/4) — a bad flash of
our image can't brick the board, and EDL (the PBL in ROM) is always
re-enterable regardless of what's on UFS.

Full stock restore uses QDL 2.3.4 with the FlatBuild package, which
rewrites every LUN:

```sh
# from the FlatBuild package's ufs/ directory
./qdl --storage ufs prog_firehose_ddr.elf rawprogram*.xml patch*.xml
```

**Danger:** the FlatBuild package's `provision/provision_ufs_1_3.xml`
re-provisions the UFS LUN layout, and per Thundercomm's own docs can
**wipe the board's serial number and Ethernet MAC** (both stored in UFS).
Never run provisioning on a working board — it is not part of either the
flash or the restore flow above.

This also inherits the 4Kn design already documented in
`tools/mk_ufs_image.py`: fwup's on-device `expand-data` op is disallowed
on this board, because sizing has to happen at image-generation time
(step 3 above), not on-device.

## Storage layout

GPT on the onboard UFS (512-byte fwup blocks; `tools/mk_ufs_image.py`
regenerates the GPT as 4096-byte LBAs for the physical EDL write):

```
p1  config   FAT     16 MiB   empty (config/provisioning store, mirrors the Q6A port's leading partition)
p2  efi      FAT32   64 MiB   BOOTAA64.EFI, grub.cfg, grubenv
p3  rootfs-a squashfs 512 MiB /boot/Image + DTB inside
p4  rootfs-b squashfs 512 MiB
p5  data     ext4    512 MiB+ /data (expand=true)
```

The M.2 NVMe slot is enabled in the kernel config and DTS and is expected
to be mountable, but is not used for boot or application data — the
onboard UFS is the sole boot disk on this board (unlike the Q6A port,
which supports either NVMe or UFS as the boot disk).

## AI foundation contract

What this system aims to guarantee to applications (config-reviewed;
**not yet device-validated** on this board — see the status table above):

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` expected present;
  DMA-BUF system heap at `/dev/dma_heap/system`; Venus at `/dev/video0`
  (dec) and `/dev/video1` (enc).
- **Firmware** (`/lib/firmware/qcom/...`, installed by
  `package/rubik-pi3-firmware`): a board-native ADSP pair from upstream
  linux-firmware (`qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn` =
  `ADSP.HT.5.5.c8-00217-KODIAK-1`, with matching fastrpc shells), and a
  generic CDSP pair (`qcom/qcs6490/cdsp.mbn` = `CDSP.HT.2.5.c3-00134-KODIAK-1`
  — the same generic c3 line the Q6A port proved on a mainline kernel,
  since no RubikPi3-specific CDSP set exists upstream). Adreno GMU/SQE/zap
  (`a660_*`) and Venus (`vpu-2.0/venus.mbn`) firmware come from the same
  linux-firmware pin.
- **DSP-side libraries**: `/usr/lib/dsp/cdsp` and `/usr/lib/dsp/adsp`
  (per-domain dirs — the sysmon skel filenames collide between sets).
  fastrpc's built-in search path is patched to include both, `cdsp/`
  first; ADSP-domain processes should set `ADSP_LIBRARY_PATH` explicitly.
- **fastrpc userspace**: `libcdsprpc.so`/`libadsprpc.so`, the
  `adsprpcd`/`cdsprpcd` daemons, and `fastrpc_test` (+ v68 test skels) —
  same `package/fastrpc` build as the Q6A port, pinned to v1.0.4.
- **`libstdc++` in the target rootfs** — required by QAIRT, same as the
  Q6A port.
- **QAIRT is NOT shipped.** Applications provision the QAIRT runtime
  bundle (and models) to `/data` themselves, same contract as the Q6A
  port.
- **udev rules** at `/etc/udev/rules.d/99-qcom-ai.rules` are the
  documented device-permission contract; they are inert on Nerves itself
  (no udev; the app runs as root) but apply in containers/dev images.

A build-time matched-pair check (`rubik-pi3-firmware.mk`) fails the build
if the installed CDSP/ADSP `.mbn` and their fastrpc shells don't carry the
same `QC_IMAGE_VERSION_STRING` — a mismatch would otherwise only surface
at runtime as fastrpc error `0x80000600` with no kernel log (a trap hit
twice during the Q6A bring-up).

## DSP daemon supervision (deliberate non-decision)

Same approach as the Q6A port: the system SHIPS the fastrpc daemons
(`adsprpcd`, `cdsprpcd`) but does NOT start or supervise them — there is
no init system on Nerves. Supervision is app-level: start them from your
OTP application (e.g. with [MuonTrap](https://hex.pm/packages/muontrap))
so restarts, backoff, and shutdown ride the app's supervision tree.

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

## WiFi / Bluetooth (onboard AP6256)

Unlike the Q6A port (out-of-tree AIC8800 driver), this board's onboard
AMPAK AP6256 module (BCM43456-class, a CYW4345 C5 die) is driven entirely
by **mainline in-tree drivers**:

- **WiFi**: SDIO on `&sdhc_2`, `brcmfmac`/`brcmutil` kernel modules
  (`CONFIG_BRCMFMAC=m`, `CONFIG_BRCMFMAC_SDIO=y`). Firmware
  (`brcmfmac43456-sdio.bin`/`.clm_blob`) comes from armbian/firmware,
  the de-facto distribution point for this chip's FullMAC firmware.
  Board NVRAM comes from the vendor's own `rubikpi-ai/rubikpi3-firmware`
  repo (byte-identical to armbian's copy) and is installed under both the
  board-specific and generic filenames brcmfmac looks for.
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
this way) but **has not been exercised on real hardware** — device
verification is pending, same as the rest of this target.

## Container runtime (balenaEngine)

Ported from the Q6A/rpi3_64 stack to bring this board to platform parity
(HA Core and add-ons run as containers) — not yet device-proven here.
Three pieces:

| Piece | Where |
| --- | --- |
| Engine binary | `package/vagus-balena-engine` (byte-for-byte copy of rpi3_64's/dragon_q6a's) + `BR2_PACKAGE_VAGUS_BALENA_ENGINE=y`, `BR2_PACKAGE_LIBSECCOMP=y` |
| Kernel support | `linux-containers.config` — a **shared** fragment (`shared/`, `make sync`, `make check`); overlayfs, cgroup controllers, netfilter + legacy iptables + NAT, bridge/veth, seccomp, `CGROUP_BPF` |
| Runtime mounts | `rootfs_overlay/etc/erlinit.config` mounts `cgroup2` on `/sys/fs/cgroup` and `configfs`; both GRUB slots pass `cgroup_no_v1=all cgroup_enable=memory` |

## VERSIONS (target stack — not yet device-validated)

| Component | Version | Notes |
|---|---|---|
| Boot-chain firmware | EDK2 UEFI + XBL/TZ/hypervisor, Thundercomm's build (UFS LUNs 1/2/4) | provides the (unused-by-default) firmware DT |
| Kernel | mainline **7.1.4** + 1 patch (`patches/linux/0003-*`) | in-tree `qcs6490-thundercomm-rubikpi3` DTS; the one carried patch is a SoC-generic qmp-ufs HS-G4 PHY init-table fix (sc7280), not board-specific |
| Devicetree | in-tree `qcom/qcs6490-thundercomm-rubikpi3.dtb` (7.1.4) | loaded by GRUB from the active slot |
| GRUB | 2.12 (Buildroot), arm64-efi | builtin modules incl. `squash4`, `loadenv`, `fdt`, `regexp` |
| Buildroot | 2026.05 via nerves_system_br 1.34.0 | |
| Toolchain | `aarch64-nerves-linux-gnu` 15.3.0 (glibc) | `-march=armv8.2-a` |
| linux-firmware | 20260410 (Buildroot pin) | source for Adreno/Venus/GENI/CDSP blobs |
| CDSP firmware | `qcom/qcs6490/cdsp.mbn` = **CDSP.HT.2.5.c3-00134-KODIAK-1** | matched pair with shells below; same generic set the Q6A port validated |
| CDSP shells/skels | hexagon-dsp-binaries `qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1` | → `/usr/lib/dsp/cdsp` |
| ADSP firmware | `qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn` = **ADSP.HT.5.5.c8-00217-KODIAK-1** | board-native pair (upstream linux-firmware ships a RubikPi3 board dir) |
| ADSP shells | hexagon-dsp-binaries `qcs6490/Thundercomm/RubikPi3/ADSP.HT.5.5.c8-00217-KODIAK-1` | → `/usr/lib/dsp/adsp` |
| fastrpc userspace | v1.0.4 (qualcomm/fastrpc) | search path patched to `/usr/lib/dsp/{cdsp,adsp}` |
| Venus firmware | `qcom/vpu-2.0/venus.mbn` (= `vpu/vpu20_p1.mbn`) | |
| WiFi/BT firmware | brcmfmac43456-sdio.{bin,clm_blob} + board NVRAM (armbian/vendor pins), BCM4345C5.hcd (vendor pin) | installed by `package/rubik-pi3-firmware` |
| wpa_supplicant | Buildroot pin, rpi3_64 option set (incl. `CTRL_IFACE`) | vintage_net_wifi's required control socket |
| wireless-regdb | Buildroot pin | mandatory — this kernel sets `CFG80211_REQUIRE_SIGNED_REGDB=y` |
| balenaEngine | v25.0.14, ported from the Q6A/rpi3_64 package | not yet device-proven on this board |

**Matched-pair rule:** the CDSP/ADSP firmware and their fastrpc shells
must carry the same `QC_IMAGE_VERSION_STRING`. The build enforces this
(see `rubik-pi3-firmware.mk`); a mismatch that slipped past the build
check would fail at runtime with fastrpc error `0x80000600` and no
kernel log.

## Lineage

This target is a hard fork of `dragon_q6a` (same QCS6490/Kodiak SoC, same
EDK2 UEFI + GRUB2 A/B boot chain, same AI-foundation contract). Where a
design choice or comment traces back to the Q6A port's device-proven
bring-up rather than something verified on this board, the source is
called out explicitly (e.g. the DTB-fixup rationale in `grub.cfg`, the
partition-layout precedent in `fwup_include/fwup-common.conf`). See
`dragon_q6a/README.md` for the original board's own (device-proven)
documentation, and `docs/dragon-q6a-flashing.md` for the EDL flashing
runbook this target's `tools/mk_ufs_image.py` was carried over from.

## Using / building

Same workflow as the other systems in this monorepo (see the [root
README](../README.md)):

```sh
cd rubik_pi3
mix deps.get
mix compile
```

That validates the system project itself (Mix/Nerves package metadata,
dependency resolution) without needing a local Buildroot toolchain. A
full firmware build additionally needs one; this workspace's devcontainer
provides a native (no Docker-in-Docker) build environment for that. In
normal use, consuming projects skip local builds entirely and pull the
CI-built artifact from this repo's GitHub Releases via a `sparse:` git
dependency (see the root README's "How CI publishes" section) — CI builds
this target's artifact on every tagged release, same as every other
target in this repo.
