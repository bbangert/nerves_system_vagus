# Thundercomm Rubik Pi 3 (QCS6490)

This is the Nerves System configuration for the Thundercomm Rubik Pi 3 — a
general-purpose aarch64 target with a first-class **on-device AI
foundation** (Hexagon NPU via fastrpc, Venus video codec, Adreno GPU).

It is a **hard fork of this repo's `dragon_q6a` target**: same SoC
(QCS6490/Kodiak), same UEFI + GRUB2 A/B boot chain, same AI-foundation
contract (fastrpc/CDSP/ADSP, DMA-BUF heap, Venus). The differences are
board-level — onboard WiFi/BT is an AP6256 module over mainline `brcmfmac`
instead of the Q6A's AIC8800, and ethernet is a USB AX88179B instead of an
onboard RTL8125. It has been brought up on a real board: see
"Device-proven status" below for what is proven and the few gates still
waiting on hardware (a monitor, a fan) or app-level work.

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
| Video          | Venus V4L2 M2M decoder + encoder (`/dev/video0`/`1`, order varies — match on `/sys/class/video4linux/*/name`) |
| Display        | HDMI out via an lt9611 bridge                        |
| Fan            | Native PWM fan with dts thermal cooling maps          |
| Expansion      | 40-pin header                                        |
| Serial console | `ttyMSM0` (GENI debug UART, 115200n8) — board micro-USB port via an onboard WCH CH343 bridge (`1a86:55d3`, host sees `/dev/ttyACM0`) |
| Boot           | Qualcomm UEFI (Thundercomm build, on the UFS boot LUNs — no SPI NOR on this board) → GRUB2 arm64-efi → A/B |
| Watchdog       | gunyah_wdt (Gunyah hypervisor owns the APSS watchdog) + nerves_heart |
| Containers     | podman 6.1.4 + netavark (nftables) + cgroup v2 — same stack as the Q6A |

## Device-proven status

Brought up on hardware 2026-10-23 (128 GB UFS board, stock Thundercomm
boot firmware `BOOT.MXF.1.0.c1-00364-KODIAKLA-1`): first on the
mainline-7.2.10 build, then on this tree's qcom-next kernel. "proven" below
means on qcom-next unless marked. The gate checklist (mirroring the Q6A
port's):

| Gate | Status |
| --- | --- |
| Boot / serial console | **proven**: UEFI → GRUB → mainline DTB → kernel under Gunyah → UFS squashfs root (mounted at 9.3 s) → iex on `ttyMSM0`; `/data` formats to full size (110.9 GiB) on first boot |
| UFS root (4Kn GPT via `tools/mk_ufs_image.py`) | **proven**; firmware boots the 512-BPB FAT ESP on the 4096-byte-sector LUN fine |
| WiFi interface / BT controller probe | **proven**: `wlan0` up, BCM4345C5 attaches |
| fastrpc / dma-heap / Venus device nodes | **proven present**; workloads in the fastrpc and Venus rows below |
| Ethernet (AX88179B) + USB3 Type-A | **proven**: uPD720201 loads `renesas_usb_fw.mem` from `usb_fw`, runs SuperSpeed; `eth0` (`cdc_ncm`) gets DHCP and reaches the internet. Failed on 7.2.10 |
| Watchdog | **proven**: `gunyah_wdt` backs `/dev/watchdog0`, nerves_heart arms it (32 s). Failed on 7.2.10 |
| RTC / clock | **proven**: PMIC RTC (`allow-set-time`) holds time across reboot, but not across power removal: the board has no RTC backup battery. A board whose RTC was never set (or lost power) boots at 1970, and NervesTime's ntpd (started before DHCP/DNS) takes ~3 min to sync, so TLS fails until then; apps that need TLS at boot should wait for `NervesTime.synchronized?/0` |
| GPU / display | **proven probe**: msm DRM binds DSI + DP + Adreno, `/dev/dri/card0` + `renderD128`, a660 SQE/GMU firmware load, LT9611 bridge detected; no monitor attached yet, so HDMI scan-out untested. Failed on 7.2.10 |
| USB-C gadget (`usb0`) | not provided: the UDC (`a600000.usb`) probes, but this system (like `dragon_q6a`) configures no gadget function, so the `usb0` a `nerves.new` app config lists never appears |
| M.2 NVMe + `rootdisk0` aliasing | **proven** with a Samsung 970 EVO Plus 1 TB (Gen3 x2): UFS stays `rootdisk0`, `nvme0n1` probes at boot (nvme is `=m`, so it never delays root), ~1 GiB/s direct reads with ASPM L1 on. Needs `aspm-no-l1ss` on `&pcie1_port0` (kernel patch 0004): with L1.1 allowed the link drops right after identify |
| WiFi STA (WPA2/WPA3) + AP mode | scan **proven** (both bands; give `quick_scan` ~10 s). WPA2-PSK: **proven** with firmware 7.45.96.215 (5 GHz connect, DHCP, `:internet`, 32 MiB each way over SSH at ~8 MiB/s; the old 7.45.96.0 was rejected by every AP with status 16). WPA3-SAE: **not supported**, a driver port was tried and the firmware still fails to associate (see "WiFi / Bluetooth"). AP mode untested |
| BT / Improv provisioning | controller **proven** (powers on under BlueZ 5.79, discovers devices; bluetoothd + dbus started by hand); Improv pending |
| podman containers | **proven**: `hello-world` (arm64v8) and an alpine container reaching the internet over the default netavark bridge. `<graphroot>/tmp` must exist first (Vagus creates it), and pulls need a synced clock |
| Home Assistant stack | pending |
| Thermal fan control | driver side **proven**, no fan fitted to the test board: `pwm-fan` cooling device (states 0-3 → PWM 0/64/…/255) bound to `cpu0-thermal` trips at 65/80 °C; idles at 0 at ~45 °C. Spin-up with a fan attached is untested |
| OTA A/B update cycle | **proven** A → B → A over SSH (`fwup` subsystem); each new slot boots and reports `firmware_valid?` |
| ADSP/CDSP fastrpc | **proven** CDSP: `fastrpc_test -a v68` 3/3 on the GRUB-loaded mainline DT. Both DSPs Online; `fastrpc-healthcheck` can't confirm modules (it expects meta-qcom's `/usr/share/qcom` build-ID layout) |
| NPU (Hexagon v68 HTP) via QAIRT | **proven** with QAIRT 2.47.0.260601 provisioned to `/data/qairt` (not shipped): `qnn-platform-validator --backend dsp` passes (V68, unit test). A v68 HTP context binary (built on the host with `soc_model` 93) runs under `qnn-net-run --retrieve_context`: 282 µs on the accelerator, 0.82 ms including the fastrpc round trip. Output matches the CPU float reference (cosine 0.99985). Needs `ADSP_LIBRARY_PATH="/data/qairt/dsp;/usr/lib/dsp/cdsp"`; `persist`/QWES licenses are not involved |
| Venus video codec | **proven** decode: `test_src/venus_dec_smoke` 30/30 frames |
| GPU render node | `renderD128` present, a660 SQE/GMU firmware loads; no userspace to exercise it (Mesa not shipped) |

## Boot chain and A/B updates

PBL → XBL → Qualcomm UEFI (Thundercomm's build; XBL/UEFI/TZ/hyp and the
firmware DT all live on UFS LUNs 1-6 — this board has no SPI NOR) loads
`\EFI\BOOT\BOOTAA64.EFI` (GRUB2, arm64-efi) from the ESP on UFS LUN0, the
only LUN Nerves writes. The firmware takes the removable-media path (stock
ships systemd-boot there), shows no boot menu, and runs Linux under the
Gunyah hypervisor. GRUB
reads `grubenv` for the active slot and boots the kernel `Image` **from
inside the active squashfs slot** (`squash4` module), so kernel,
devicetree, firmware blobs, and rootfs update atomically per slot. fwup's
uboot-env block carries the Nerves metadata; `upgrade.a`/`upgrade.b` flip
both stores.

**The mainline DTB is loaded explicitly by GRUB** (`fdt` module,
`devicetree` command) from the active slot rather than relying on the
firmware-provided DT. On the Q6A port (same SoC, Radxa's EDK2/6.18-era
firmware DT), the firmware DT's CDSP reserved-memory layout mismatched
the mainline board DTS's, so the CDSP booted but every fastrpc invoke
failed. The
same explicit-DTB fixup is carried here on the presumption that
Thundercomm's firmware DT has an analogous mismatch (not checked; the
explicit load is proven to boot). If the DTB load fails, `grub.cfg` falls
back to the firmware DT (system still boots; DSP offload degraded).

Serial console: `ttyMSM0` (GENI debug UART, mainline dts
`serial0 = &uart5`), 115200n8, on the board's micro-USB port.

## Flashing

Qualcomm EDL over the USB-C port, with [qdl](https://github.com/linux-msm/qdl)
(2.x; built from source with `-Dnbdkit=disabled`) and
`prog_firehose_ddr.elf` from Thundercomm's FlatBuild package. Enter EDL by
holding the EDL button while applying power; the host sees `05c6:9008`.
Write **LUN0 only** — LUNs 1-6 hold the boot firmware and are never touched:

```bash
mix firmware
fwup -a -t complete -i _build/rubik_pi3_dev/nerves/images/<app>.fw -d rubik_pi3.img
# Exact LUN0 capacity: 29976576 sectors x 4096 on the 128 GB module (the
# kernel's sd 0:0:0:0 line or the stock GPT's BackupLBA + 1 gives it).
python3 rubik_pi3/tools/mk_ufs_image.py --input rubik_pi3.img \
    --disk-bytes $((29976576 * 4096)) --out rubik_pi3_ufs
qdl --storage ufs prog_firehose_ddr.elf \
    write 0/0 rubik_pi3_ufs.img \
    write 0/29976571 rubik_pi3_ufs-backup-gpt.bin   # LBA the tool prints
```

qdl resets the board when it finishes; it boots straight into Nerves.

**Back up `persist` first.** Stock LUN0 is `efi` (512 MiB), `persist`
(30 MiB, ext4: factory QTEE/QWES attestation and license stores) and
`system`. The Nerves layout overwrites `persist` (it sits inside `rootfs-a`)
and the FlatBuild never rewrites it (empty `filename` in `rawprogram0.xml`),
so take it while it's there:

```bash
qdl --storage ufs prog_firehose_ddr.elf read 0/persist lun0_persist.bin
```

To go back to stock: flash the FlatBuild's `rawprogram0.xml` + `patch0.xml`
(LUN0), then `qdl --storage ufs prog_firehose_ddr.elf write 0/persist
lun0_persist.bin`.

Do **not** run fwup's `expand-data` on this board: fwup's `gpt_write()` is
hardwired to 512-byte LBAs and would corrupt the 4Kn GPT.
`mk_ufs_image.py` already sizes `/data` to fill LUN0.

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

The M.2 NVMe slot works as extra storage, but this system doesn't use it for
boot or application data. The onboard UFS is the only boot disk on this board
(unlike the Q6A port, which can boot from NVMe or UFS). nvme is built as a
module so a slow or failing SSD can't hold up the root mount.

pcie-qcom turns on every ASPM state, L1.1/L1.2 included, for devices present
when the host bridge probes. On this slot the link drops as soon as L1.1 is
allowed: "Recovering Root Port due to Link Down" ~50 ms after nvme identify,
then a 60 s admin timeout. This was bisected on hardware: L1 and Clock PM are
fine, L1.1 breaks it. Forcing the PHY endpoint refclk on (Thundercomm's
downstream `qcom,refclk-always-on`) didn't help. Patch 0004 keeps L1 and blocks
the substates with `aspm-no-l1ss`. The `arm-smmu ... iova=0x40100000
cbfrsynra=0x1c80` fault that sometimes follows NVMe probe comes from the Root
Port's own AER/PME MSI (SID 0x1c80 is RID 0). qcom-next keeps that MSI enabled
as a workaround (it reverts upstream f5cd8a929c82). The fault is harmless to
the NVMe, but Root Port AER/PME interrupts are lost.

## AI foundation contract

What this system guarantees to applications. Each item is device-proven on
this board; see the fastrpc, Venus and NPU rows of the status table above:

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` expected present;
  DMA-BUF system heap at `/dev/dma_heap/system`; two Venus nodes, a decoder
  and an encoder, at `/dev/video0` and `/dev/video1` in either order (module
  load order; seen as video0 = encoder on this board) — identify them by
  `/sys/class/video4linux/*/name` (`qcom-venus-decoder` /
  `qcom-venus-encoder`).
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
  `adsprpcd`/`cdsprpcd` daemons in `/usr/sbin`, `fastrpc_test` (+ v68 test
  skels) and upstream's `fastrpc-healthcheck` in `/usr/bin` — same
  `package/fastrpc` build as the Q6A port, pinned to v1.0.8.
- **`libstdc++` in the target rootfs** — required by QAIRT, same as the
  Q6A port.
- **QAIRT is NOT shipped.** Applications provision the QAIRT runtime
  bundle (and models) to `/data` themselves, same contract as the Q6A
  port.
- **udev rules** at `/etc/udev/rules.d/99-qcom-ai.rules` are the
  documented device-permission contract; they are inert on Nerves itself
  (no udev; the app runs as root) but apply in containers/dev images.
  fastrpc upstream also installs `/lib/udev/rules.d/60-fastrpc.rules`
  (`root:fastrpc` `0640` on the non-secure nodes) and
  `/usr/lib/sysusers.d/fastrpc.conf`, equally inert here. Where udev does
  evaluate rules, `99-qcom-ai.rules` sorts later, so its `MODE="0666"` is
  the one that applies.

A build-time matched-pair check (`rubik-pi3-firmware.mk`) fails the build
if the installed CDSP/ADSP `.mbn` and their fastrpc shells don't carry the
same `QC_IMAGE_VERSION_STRING` — a mismatch would otherwise only surface
at runtime as fastrpc error `0x80000600` with no kernel log (a trap hit
twice during the Q6A bring-up).

## DSP daemon supervision (deliberate non-decision)

Same approach as the Q6A port: the system SHIPS the fastrpc daemons
(`adsprpcd`, `cdsprpcd`, in `/usr/sbin`) but does NOT start or supervise
them — there is
no init system on Nerves. Supervision is app-level: start them from your
OTP application (e.g. with [MuonTrap](https://hex.pm/packages/muontrap))
so restarts, backoff, and shutdown ride the app's supervision tree.

```sh
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &
```

Bare names resolve because `/usr/sbin` is on erlinit's default `PATH`.

## WiFi / Bluetooth (onboard AP6256)

Unlike the Q6A port (out-of-tree AIC8800 driver), this board's onboard
AMPAK AP6256 module (BCM43456-class, a CYW4345 C5 die) is driven entirely
by **mainline in-tree drivers**:

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

## Container runtime (podman)

The same stack as `dragon_q6a`, so HA Core and apps run as containers that
Vagus drives through the `podman` CLI (device-proven; see the status table).
Three pieces:

| Piece | Where |
| --- | --- |
| Engine | `package/vagus-podman` (podman 6.1.4, with the baked `/etc/containers/containers.conf` and `storage.conf`), `package/vagus-netavark` (netavark 2.1.0, nftables driver, no aardvark-dns), `package/vagus-crun` (crun 1.30.1), all synced from `shared/package/` by `make sync`; Buildroot's `conmon`, `catatonit`, `containers-image-config`, `nftables` and util-linux |
| Kernel support | `linux-containers.config` — a **shared** fragment (`shared/`, `make sync`, `make check`); overlayfs, cgroup controllers, nftables + NAT, bridge/veth, seccomp, `CGROUP_BPF` |
| Runtime mounts | `rootfs_overlay/etc/erlinit.config` mounts `cgroup2` on `/sys/fs/cgroup` and `configfs`; both GRUB slots pass `cgroup_no_v1=all cgroup_enable=memory` |

## VERSIONS (target stack, device-validated 2026-10-23)

| Component | Version | Notes |
|---|---|---|
| Boot firmware | Thundercomm `BOOT.MXF.1.0.c1-00364-KODIAKLA-1` (XBL + UEFI 6.0.250904) on UFS LUNs 1-6 | not written by Nerves; provides the (unused-by-default) firmware DT |
| Kernel | Qualcomm **qcom-next** tag `qcom-next-7.3-rc4-20261014` (7.3.0-rc4) + 2 patches (`patches/linux/`) | the kernel meta-qcom builds for QCS6490 (`linux-qcom-next`, same pin). `0003` is the SoC-generic qmp-ufs HS-G4 PHY init table (sc7280) from Radxa's kernel tree; `0004` sets `aspm-no-l1ss` on the M.2 port. Neither is in mainline or qcom-next |
| Devicetree | in-tree `qcom/qcs6490-thundercomm-rubikpi3.dtb` (qcom-next) | loaded by GRUB from the active slot |
| GRUB | 2.12 (Buildroot), arm64-efi | builtin modules incl. `squash4`, `loadenv`, `fdt`, `regexp` |
| Buildroot | 2026.05.2 via nerves_system_br 1.34.4 | Erlang/OTP 29.0.6 |
| Toolchain | `aarch64-nerves-linux-gnu` 15.3.0 (glibc) | `-march=armv8.2-a` |
| linux-firmware | 20260410 (Buildroot pin) | source for Adreno/Venus/GENI/CDSP blobs |
| CDSP firmware | `qcom/qcs6490/cdsp.mbn` = **CDSP.HT.2.5.c3-00134-KODIAK-1** | matched pair with shells below; same generic set the Q6A port validated |
| CDSP shells/skels | hexagon-dsp-binaries `qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1` | → `/usr/lib/dsp/cdsp` |
| ADSP firmware | `qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn` = **ADSP.HT.5.5.c8-00217-KODIAK-1** | board-native pair (upstream linux-firmware ships a RubikPi3 board dir) |
| ADSP shells | hexagon-dsp-binaries `qcs6490/Thundercomm/RubikPi3/ADSP.HT.5.5.c8-00217-KODIAK-1` | → `/usr/lib/dsp/adsp` |
| fastrpc userspace | v1.0.8 (qualcomm/fastrpc) | search path patched to `/usr/lib/dsp/{cdsp,adsp}` |
| QAIRT | — not shipped (user-provisioned to `/data/qairt`); **2.47.0.260601 validated on this system** | `lib/aarch64-oe-linux-gcc11.2` → `/data/qairt/lib`, `lib/hexagon-v68/unsigned` → `/data/qairt/dsp`; HTP validator PASS and a context-binary graph run, 2026-10-23 |
| Venus firmware | `qcom/vpu-2.0/venus.mbn` (= `vpu/vpu20_p1.mbn`) | |
| WiFi/BT firmware | brcmfmac43456-sdio.{bin,clm_blob} + board NVRAM (armbian/vendor pins), BCM4345C5.hcd (vendor pin) | installed by `package/rubik-pi3-firmware` |
| wpa_supplicant | Buildroot pin, rpi3_64 option set (incl. `CTRL_IFACE`) | vintage_net_wifi's required control socket |
| wireless-regdb | Buildroot pin | mandatory — this kernel sets `CFG80211_REQUIRE_SIGNED_REGDB=y` |
| podman | 6.1.4, with netavark 2.1.0, crun 1.30.1, conmon 2.1.8, catatonit 0.2.1 (same packages as `dragon_q6a`) | `hello-world` and an alpine container with bridge networking, 2026-10-23 |

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
