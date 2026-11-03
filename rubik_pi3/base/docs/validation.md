# Validation evidence

What has been proven on a real Rubik Pi 3, and on which software. The
Hardware support table in the [README](../README.md) cites this page.

These proofs were taken while this system lived in
[nerves_system_vagus](https://github.com/bbangert/nerves_system_vagus) as
its `rubik_pi3` target (the v0.5.x line: nerves_system_br 1.34.4,
Buildroot 2026.05.2, Erlang/OTP 29.0.6, toolchain 15.3.0). The move to
nerves_system_br 1.35.3 / toolchain 15.3.1 (v0.6.0 there, v0.1.0 here) is
build-proof only until the gates below are re-run.

The tables are kept as recorded. Rows about podman and the Home Assistant
stack exercised that product's layer on top of this system; this system
does not ship them.

## Gate checklist

Brought up on hardware 2026-10-23 (128 GB UFS board, stock Thundercomm
boot firmware `BOOT.MXF.1.0.c1-00364-KODIAKLA-1`): first on the
mainline-7.2.10 build, then on the qcom-next kernel. "proven" means on
qcom-next unless marked.

| Gate | Status |
| --- | --- |
| Boot / serial console | **proven**: UEFI → GRUB → mainline DTB → kernel under Gunyah → UFS squashfs root (mounted at 9.3 s) → iex on `ttyMSM0`; `/data` formats to full size (110.9 GiB) on first boot |
| Hostname / board id | pending: `nerves-<last 4 of the SoC serial>` from `/sys/devices/soc0/serial_number` (`QCOM_SOCINFO=y`); was `nerves-0000` because the USB `eth0` appears after erlinit |
| UFS root (4Kn GPT via `tools/mk_ufs_image.py`) | **proven**; firmware boots the 512-BPB FAT ESP on the 4096-byte-sector LUN fine |
| WiFi interface / BT controller probe | **proven**: `wlan0` up, BCM4345C5 attaches |
| fastrpc / dma-heap / Venus device nodes | **proven present**; workloads in the fastrpc and Venus rows below |
| Ethernet (AX88179B) + USB3 Type-A | **proven**: uPD720201 loads `renesas_usb_fw.mem` from `usb_fw`, runs SuperSpeed; `eth0` (`cdc_ncm`) gets DHCP and reaches the internet. Failed on 7.2.10 |
| Watchdog | **proven**: `gunyah_wdt` backs `/dev/watchdog0`, nerves_heart arms it (32 s). Failed on 7.2.10 |
| RTC / clock | **proven**: PMIC RTC (`allow-set-time`) holds time across reboot, but not across power removal: no backup battery was fitted to the tested board's 2-pin RTC connector. A board whose RTC was never set (or lost power) boots at 1970, and NervesTime's ntpd (started before DHCP/DNS) takes ~3 min to sync, so TLS fails until then; apps that need TLS at boot should wait for `NervesTime.synchronized?/0`. `CONFIG_RTC_HCTOSYS` is off because `rtc-pm8xxx` is a module: its hctosys ran after nerves_time had set the clock and dragged it back to 1970 |
| GPU / display | **proven probe**: msm DRM binds DSI + DP + Adreno, `/dev/dri/card0` + `renderD128`, a660 SQE/GMU firmware load, LT9611 bridge detected; no monitor attached yet, so HDMI scan-out untested. Failed on 7.2.10 |
| USB-C gadget (`usb0`) | not provided: the UDC (`a600000.usb`) probes, but this system (like nerves_system_q6a) configures no gadget function, so the `usb0` a `nerves.new` app config lists never appears |
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
(see `package/rubik-pi3-firmware/rubik-pi3-firmware.mk`); a mismatch that
slipped past the build check would fail at runtime with fastrpc error
`0x80000600` and no kernel log.
