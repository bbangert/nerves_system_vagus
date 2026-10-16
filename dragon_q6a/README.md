# Radxa Dragon Q6A (QCS6490)

This is the Nerves System configuration for the Radxa Dragon Q6A — a
general-purpose aarch64 target with a first-class **on-device AI
foundation** (Hexagon NPU via fastrpc, Venus video codec).

| Feature        | Description                                     |
| -------------- | ----------------------------------------------- |
| CPU            | QCS6490 (4x Cortex-A78 + 4x Cortex-A55)         |
| Memory         | 4/8/16 GB LPDDR4x                               |
| Storage        | NVMe (M.2) or UFS module — both device-proven   |
| Ethernet       | RTL8125 2.5 GbE (r8169 driver, `eth0`)          |
| NPU/DSP        | Hexagon v68 CDSP (~12 TOPS) via fastrpc         |
| Video          | Venus V4L2 M2M decoder + encoder (`/dev/video*`) |
| GPU            | Adreno 643 (drm/msm module; userspace not shipped) |
| Serial console | `ttyMSM0` (GENI debug UART, 115200n8)           |
| Boot           | EDK2 UEFI (SPI NOR) → GRUB2 arm64-efi → A/B     |
| Watchdog       | qcom_wdt + nerves_heart                         |
| Containers     | podman 6.1.4 + netavark (nftables) + cgroup v2 — not yet device-proven on this image |

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
(`cdsp_mem@8e000000`) mismatches the mainline board DTS's
(`cdsp_mem@87000000`) — with the firmware DT the CDSP boots but every
fastrpc invoke fails (device-proven 2026-07-24 on kernel 7.1). If the DTB
load fails, grub.cfg falls back to the firmware DT (system boots; DSP
offload degraded). Memory and XBL reservations always arrive via the
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

What this system guarantees to applications (device validation is recorded
per component under VERSIONS):

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` present; DMA-BUF system
  heap at `/dev/dma_heap/system`; two Venus nodes, a decoder and an
  encoder, at `/dev/video0` and `/dev/video1`. Which is which follows
  module load order and was observed both ways (`video0` = decoder on
  kernel 7.1.4, `video0` = encoder on 7.2.10), so identify them by
  `/sys/class/video4linux/*/name`: `qcom-venus-decoder` /
  `qcom-venus-encoder`.
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
  `adsprpcd`/`cdsprpcd` daemons in `/usr/sbin`, `fastrpc_test` (+ v68 test
  skels) and upstream's `fastrpc-healthcheck` in `/usr/bin`.
  `fastrpc_test -a v68` passed 3/3 out of the box on fastrpc v1.0.4 and
  kernel 7.1.4; see VERSIONS for the shipped pin.
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
  fastrpc upstream also installs `/lib/udev/rules.d/60-fastrpc.rules`
  (`root:fastrpc` `0640` on the non-secure nodes) and
  `/usr/lib/sysusers.d/fastrpc.conf`, equally inert here. Where udev does
  evaluate rules, `99-qcom-ai.rules` sorts later, so its `MODE="0666"` is
  the one that applies.

## DSP daemon supervision (deliberate non-decision)

The system SHIPS the fastrpc daemons (`adsprpcd`, `cdsprpcd`, in
`/usr/sbin`) but does NOT start or supervise them — there is no init system on Nerves. Supervision is
app-level: start them from your OTP application (e.g. with
[MuonTrap](https://hex.pm/packages/muontrap)) so restarts, backoff, and
shutdown ride the app's supervision tree. Note the daemons serve root-PD
exception logging and remote file access; plain `fastrpc_test`-style
unsigned-PD offload works without them.

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

Bare names resolve because `/usr/sbin` is on erlinit's default `PATH`. A
supervisor that spawns them by absolute path must use `/usr/sbin/…`:
fastrpc up to v1.0.5 installed them to `/usr/bin`.

## Audio playback (validated recipe)

The mixer powers up with the entire headphone path disconnected/muted.
The validated `amixer -c 0 cset` sequence (runtime state — apply from the
application at boot; `alsactl` is not shipped):

```sh
# frontend -> codec-DMA backend
amixer -c 0 cset name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1
# rx-macro: RX0/RX1 from AIF1, interpolators CONNECTED (default is ZERO!)
amixer -c 0 cset name='RX_MACRO RX0 MUX' AIF1_PB
amixer -c 0 cset name='RX_MACRO RX1 MUX' AIF1_PB
amixer -c 0 cset name='RX INT0_1 MIX1 INP0' RX0
amixer -c 0 cset name='RX INT1_1 MIX1 INP0' RX1
amixer -c 0 cset name='RX INT0_1 INTERP' 'RX INT0_1 MIX1'
amixer -c 0 cset name='RX INT1_1 INTERP' 'RX INT1_1 MIX1'
amixer -c 0 cset name='RX INT0 DEM MUX' CLSH_DSM_OUT
amixer -c 0 cset name='RX INT1 DEM MUX' CLSH_DSM_OUT
amixer -c 0 cset name='RX_COMP1 Switch' 1
amixer -c 0 cset name='RX_COMP2 Switch' 1
# wcd938x: DAC/PA path + Class-H mode (default CLS_H_INVALID = silence!)
amixer -c 0 cset name='HPHL_RDAC Switch' 1
amixer -c 0 cset name='HPHR_RDAC Switch' 1
amixer -c 0 cset name='HPHL Switch' 1
amixer -c 0 cset name='HPHR Switch' 1
amixer -c 0 cset name='HPHL_COMP Switch' 1
amixer -c 0 cset name='HPHR_COMP Switch' 1
amixer -c 0 cset name='RX HPH Mode' CLS_H_LOHIFI
# volumes (DSP stream volume defaults low; digital 84 = 0 dB)
amixer -c 0 cset name='stream0.vol_ctrl0 MultiMedia1 Playback Volu' 100%
amixer -c 0 cset name='RX_RX0 Digital Volume' 84
amixer -c 0 cset name='RX_RX1 Digital Volume' 84
amixer -c 0 cset name='HPHL Volume' 20
amixer -c 0 cset name='HPHR Volume' 20
```

Then `aplay -D hw:0,0 file.wav` (48 kHz S16_LE stereo; use `plughw` for
other formats). The two silent traps: `RX INT*_1 INTERP` defaults to
`ZERO` and `RX HPH Mode` defaults to `CLS_H_INVALID` — each alone mutes
program audio while still passing transient clicks.

## VERSIONS (validated stack)

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

**Matched-pair rule:** the CDSP firmware and the fastrpc shells must carry
the same `QC_IMAGE_VERSION_STRING` (`strings cdsp.mbn | grep QC_IMAGE`).
A mismatch fails with fastrpc error `0x80000600` and no kernel log. The
board-specific c4-00004 CDSP pair is a known dead-end on mainline kernels
(PD creates, all invokes fail) — do not swap it back without new evidence.

## Container runtime (podman)

HA Core and apps run as podman containers, which Vagus drives one operation
at a time through the `podman` CLI; there is no engine daemon. Three pieces
have to be present:

| Piece | Where |
| --- | --- |
| Engine | `package/vagus-podman` (podman 6.1.4, with the baked `/etc/containers/containers.conf` and `storage.conf`), `package/vagus-netavark` (netavark 2.1.0, nftables driver, no aardvark-dns), `package/vagus-crun` (crun 1.30.1); Buildroot's `conmon`, `catatonit`, `containers-image-config`, `nftables` and util-linux |
| Kernel support | `linux-containers.config` — a **shared** fragment (`shared/`, `make sync`, `make check`); overlayfs, cgroup controllers, nftables + NAT, bridge/veth, seccomp, `CGROUP_BPF` |
| Runtime mounts | `rootfs_overlay/etc/erlinit.config` mounts `cgroup2` on `/sys/fs/cgroup` and `configfs`; **both** GRUB slots pass `cgroup_no_v1=all cgroup_enable=memory` |

Notes for anyone touching this:

- The three `vagus-*` recipes are synced from `shared/package/` by
  `make sync`; edit them there. `make check` fails on drift.
- The baked config is profile-neutral with the frugal (small-RAM) values.
  Vagus writes `/run/vagus/podman/containers.conf` at boot and points
  `CONTAINERS_CONF_OVERRIDE` at it to pick the board's profile.
- Images live under `/root/containers/storage`; container state is in the
  transient store on `/run`, so every container is recreated each boot.
- `/etc/resolv.conf` is a symlink to `/run/resolv.conf`, not the skeleton's
  `../tmp/resolv.conf`; Vagus writes `/run/resolv.conf` at boot.
- The app-data partition mounts at `/data`, which the Nerves skeleton ships
  as a symlink to `/root` — so `mount`/`/proc/mounts` show the partition on
  **`/root`**, and container data really does live on writable storage.
  That is expected, not a misconfiguration.

**Status: not yet device-proven on this image.** podman 6.1.4 with this
netavark, crun and conmon ran Core and the bench apps on this board,
driven by hand, in a throwaway build (2026-10-13); the full Vagus stack was
device-proven on balenaEngine through v0.4.0 (Core, apps, MQTT, ingress,
OTA, unclean power cycle).

> **An OTA cannot update `grub.cfg` on this board.** `fwup.conf` writes it to
> the ESP only in `task complete` (a full flash); `upgrade.a`/`upgrade.b`
> carry the rootfs slot and `grubenv` alone. A device that OTAs into this
> version therefore keeps its previous kernel cmdline. That is fine today —
> see the `cgroup_no_v1`/`cgroup_enable` note in `grub.cfg` — but any
> *future* cmdline change on this board needs a full reflash to take effect.

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
- **Onboard WiFi/BT (AIC8800) is now shipped** — see the dedicated
  section below for what is proven and what is not. **USB BT dongles
  remain device-proven** as an alternative: a TP-Link UB500 (RTL8761BU)
  enumerated, btusb loaded the shipped `rtl_bt` firmware, and the adapter
  powered on and was discoverable over the air via bluetoothd/D-Bus.
  Note for app authors: BlueZ cancels discovery when the requesting
  D-Bus client disconnects, so inbound scanning needs a persistent client
  (e.g. the `bluez` hex library), not one-shot `dbus-send` calls.

## WiFi / Bluetooth (onboard AIC8800D80)

The board's Quectel FCU760K module (AIC8800D80, USB `a69c:8d80`) is
driven by the out-of-tree Aicsemi driver Radxa packages, built here as
two Buildroot packages pinned to the same commit:

- `package/aic8800` — the kernel modules. `aic_load_fw` uploads firmware
  (after which the chip re-enumerates as `a69c:8d81`), `aic8800_fdrv`
  presents **`wlan0`** (cfg80211 fullmac), `aic_btusb` presents **`hci0`**.
- `package/aic8800-firmware` — the proprietary blobs, installed to
  `/lib/firmware/aic8800D80/` (the path the loader actually opens).

Two non-obvious build rules live in `package/aic8800/aic8800.mk`, both
worth reading before touching the package:

1. **The raw upstream tarball does not build against this kernel.** Every
   kernel-compat fix lives in Radxa's `debian/patches/` quilt series
   (applied only by `dpkg-source` when they build their DKMS debs), so
   the package replays that series in series-file order. Two patches are
   deliberately skipped because the vendor SDK drop gave some `.c` files
   CRLF endings that the LF patches cannot apply to; neither is needed.
2. **`CONFIG_BLUEDROID` is flipped 1 → 0.** The vendor default exposes an
   Android-HAL character device instead of registering a BlueZ HCI —
   this is the root cause of every public "AIC8800 Bluetooth doesn't work
   on Linux" report. Radxa ship the same flip as a debian-only patch.

`BR2_PACKAGE_WIRELESS_REGDB=y` is **mandatory**, not cosmetic: this
kernel sets `CFG80211_REQUIRE_SIGNED_REGDB=y`, so without
`regulatory.db(.p7s)` cfg80211 fails the regdb load and the STA is stuck
in a restrictive world domain.

### BLE advertising needs a fast interval (device-proven trap)

`rootfs_overlay/etc/bluetooth/main.conf` sets
`[LE] MinAdvertisementInterval=100` / `MaxAdvertisementInterval=150`
(BlueZ reads these in 0.625 ms slots → ~62.5–93.75 ms). **Do not remove
this.** At the kernel default (1280 ms), combined with BlueZ's
advertising-instance rotation, effectively no advertising events reach
the air — while every HCI command still returns status `0x00` and
`LEAdvertisingManager1.ActiveInstances` still reads 1. The failure is
completely silent from the host's point of view.

`package/aic8800/0001-aic-btusb-mask-broken-ext-adv-feature.patch.disabled`
is a parked wrong turn kept for the record: masking the LE Extended
Advertising *feature* bit does force legacy advertising, but
`use_ext_scan`/`use_ext_conn` key off the supported-**commands** bitmap
instead, so the kernel keeps issuing extended scan/connect commands and
that mix kills LE scanning outright on this firmware (0 devices vs 84).

### Status (device-proven 2026-07-25/26, kernel 7.1.4)

On 2026-10-12, with kernel 7.2.10 and the `d13d079` driver, the WiFi scan
(2.4 and 5 GHz), BT adapter and BLE scanning rows were re-run; the other
rows were not.

| Capability | State |
|---|---|
| WiFi STA (`wlan0`) | **Works** — WPA2-PSK association, DHCP, data path; regdb loads, channels 1–165; 2.4 GHz and 5 GHz both proven |
| BT adapter (`hci0`) | **Works** — from the onboard chip on every boot, powered by bluetoothd 5.79 |
| BLE advertising (peripheral) | **Works** — Improv service advert received off-board at RSSI −13…−16 (needs the interval fix above) |
| BLE scanning (observer) | **Works** — 84–87 devices, passive AdvertisementMonitor and active discovery; steady across a multi-hour soak |
| WiFi + BLE coexistence | **Works** — scanning + advertising + an associated `wlan0`, concurrently, no interference |
| Inbound GATT (as peripheral) | **Works** — phone connected, resolved services, and completed a full Improv credential exchange |
| WPA3 / SAE association | **Works** — SAE handshake completes (`PMKSA-CACHE-ADDED` + `CTRL-EVENT-CONNECTED`), provisioned over Improv |

**Choose your test central carefully.** The inbound GATT result above came
from a phone. A Raspberry Pi 3's onboard BT 4.1 BCM43438 could *not*
connect to this board at all — every attempt ended in
`le-connection-abort-by-local` with no LE Meta / Connection Complete
event ever reaching the Q6A's HCI, which looks exactly like a firmware
that refuses `CONNECT_IND`. It isn't: a phone connects on the first try.
Do not conclude anything about this radio from a Pi-as-central test.

**WPA3 (SAE) works, including over Improv — but needs `improv >= 0.1.2`.**
Earlier versions hardcoded `key_mgmt: :wpa_psk`, so an SAE-only SSID
associated and then failed the 4-way handshake, surfacing as a misleading
"wrong password" ([bbangert/improv#2](https://github.com/bbangert/improv/issues/2)).
0.1.2 infers SAE vs PSK from the target SSID's live scan flags.

Device-proven on this board: provisioned onto an SAE-only network from a
phone, producing `key_mgmt: :sae` with `ieee80211w: 2` and a completed
handshake (`PMKSA-CACHE-ADDED` → `Associated` → `CTRL-EVENT-CONNECTED`).

**Provisioning trap that survives that fix:** the SAE inference reads the
*live* `access_points` property and never triggers a scan of its own. A
device waiting to be provisioned has no configured networks, so
wpa_supplicant is not background-scanning and that property can be empty
exactly when Improv needs it — in which case the inference silently falls
back to PSK and an SAE-only network fails as before. Observed here: the
first attempt fell back to PSK, and only a `VintageNet.scan("wlan0")`
seconds before submitting made it pick SAE. If you are debugging a failed
WPA3 provision, check the applied `key_mgmt` before suspecting the radio.

To put the board on an SAE-only network by hand, `vintage_net_wifi`
supports it directly:

```elixir
VintageNet.configure("wlan0", %{
  type: VintageNetWiFi,
  vintage_net_wifi: %{
    networks: [%{key_mgmt: :sae, ssid: "...", sae_password: "...", ieee80211w: 2}]
  },
  ipv4: %{method: :dhcp}
})
```

`ieee80211w: 2` (management-frame protection required) is mandatory for
WPA3 — omit it and the association fails.

Kernel-config note: `linux-7.2.defconfig` sets `CONFIG_IP_ADVANCED_ROUTER`
+ `CONFIG_IP_MULTIPLE_TABLES` for the radio. `vintage_net`'s
RouteManager hard-requires policy routing — without it every `set_route`
fails with RTNETLINK "Operation not supported", RouteManager crash-loops,
and the whole `vintage_net` application goes down (which an ethernet-only
board never notices, because ssh keeps working).

### Tracking upstream (do this on every kernel bump)

1. Apply `patches/linux/*` in order to a scratch copy of the new tree with
   `patch -p1 --fuzz=0`. Regenerate any patch that needs fuzz or an offset;
   drop one only once its change is in the new tree.
2. Build the aic8800 driver against the new kernel. If the replayed series
   fails, look at what [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800)
   has added to `debian/patches/series` since the pin and move both aic8800
   packages to a commit whose series builds. A missing
   `fix-linux-<series>-build.patch` proves nothing by itself: upstream adds
   one only for a kernel that broke the build. While there —
   if the two skipped patches were refreshed (or line endings normalized),
   prefer dropping the skip over carrying it.
3. Check Armbian's DKMS version guard in
   [`extensions/radxa-aic8800.sh`](https://github.com/armbian/build/blob/main/extensions/radxa-aic8800.sh)
   and their kernel-bump PRs — the guard tells you which kernels upstream
   believes the driver builds against. **Never sync this package to their
   extension blindly:** Armbian compiles the source with `CONFIG_BLUEDROID`
   *unflipped*, i.e. with no working BlueZ Bluetooth.
4. Resolve the same defconfig + fragments against the old and the new tree
   and diff the two `.config`s for symbols the new kernel turns on by
   default. Audit each against the `compatible` strings in the board DTB
   and disable what nothing binds to. A driver can also take over
   a devicetree node between releases with no symbol changing, so compare
   which driver is bound to each proven device node before and after
   (`/sys/bus/platform/devices/*/driver`).
5. On both trees, list the symbols the defconfig and the fragments set
   that the resolved `.config` does not carry with the requested value.
   The list is never empty (about 110 entries: other-SoC options, and
   requests Kconfig legitimately overrides, e.g. `CONFIG_BT=y` → `m`), so
   compare the two: they must match apart from what the bump intends. A
   new entry is a renamed or re-parented symbol, dropped silently.
6. Decompile the old and new board DTBs (`dtc -I dtb -O dts`), normalise
   the phandle numbers, and diff. Every difference should trace to an
   upstream DTS change or a carried patch.
7. Rebuild and re-run the gate behind every VERSIONS row the bump moved
   or whose proof rides on something it moved. For a kernel bump: the base
   sequence at the top of VERSIONS (boot → ethernet → A/B OTA + revert →
   watchdog → `fastrpc_test` 3/3), a UFS-module boot, the Venus decode
   smoke test, the QAIRT HTP run, the container stack, and the three radio
   gates: WiFi STA association, `hci0` + BLE advertising (verify off-board,
   not just `ActiveInstances`), and a BLE scan/advertise/WiFi coexistence
   soak. A "last hardware-validated on" marker is cleared by replacing it,
   and any older proof date beside it, with the new dated proof; deleting
   the marker alone leaves the new version inside the old proof. A gate
   re-run only in part clears it only for that part: date what was re-run
   and keep the marker on the rest.
- **UFS variant**: DONE, device-proven 2026-08-02 (boot, ethernet, /data at
  full module size, A/B OTA cycle). Same `.fw`; the EDL image's GPT is
  regenerated for 4096-byte sectors by `tools/mk_ufs_image.py` ("Fork A" —
  see docs/dragon-q6a-flashing.md). One-time LUN provisioning XML lives in
  armbian/qcombin. NEVER run `expand-data` on a UFS board. Boot order with
  NVMe and UFS both fitted remains unverified.
