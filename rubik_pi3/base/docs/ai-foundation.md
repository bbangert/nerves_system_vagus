# AI foundation contract

What this system guarantees to applications (device validation is recorded
in [validation.md](validation.md)):

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp` and `/dev/fastrpc-cdsp-secure`; DMA-BUF system heap
  at `/dev/dma_heap/system`; two Venus nodes, a decoder and an encoder, at
  `/dev/video0` and `/dev/video1` in either order (module load order).
  Identify them by `/sys/class/video4linux/*/name` (`qcom-venus-decoder` /
  `qcom-venus-encoder`).
- **Firmware** (`/lib/firmware/qcom/...`, installed by
  `package/rubik-pi3-firmware`): a board-native ADSP pair from upstream
  linux-firmware (`qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn` =
  `ADSP.HT.5.5.c8-00217-KODIAK-1`, with matching fastrpc shells), and a
  generic CDSP pair (`qcom/qcs6490/cdsp.mbn` = `CDSP.HT.2.5.c3-00134-KODIAK-1`,
  since no Rubik Pi 3 CDSP set exists upstream). Adreno GMU/SQE/zap
  (`a660_*`) and Venus (`vpu-2.0/venus.mbn`) firmware come from the same
  linux-firmware pin.
- **DSP-side libraries**: `/usr/lib/dsp/cdsp` and `/usr/lib/dsp/adsp`
  (per-domain directories, because the sysmon skel filenames collide
  between sets). fastrpc's built-in search path is patched to include
  both, `cdsp/` first; ADSP-domain processes should set
  `ADSP_LIBRARY_PATH` explicitly.
- **fastrpc userspace** (v1.0.8): `libcdsprpc.so`/`libadsprpc.so`, the
  `adsprpcd`/`cdsprpcd` daemons in `/usr/sbin`, `fastrpc_test` (+ v68 test
  skels) and `fastrpc-healthcheck` in `/usr/bin`. `fastrpc-healthcheck`
  can't confirm modules here: it expects meta-qcom's `/usr/share/qcom`
  layout.
- **`libstdc++` in the target rootfs**, which QAIRT needs.
- **QAIRT is not shipped.** Applications provision the QAIRT runtime
  bundle (and models) to `/data` themselves. 2.47.0.260601 was validated
  with `ADSP_LIBRARY_PATH="/data/qairt/dsp;/usr/lib/dsp/cdsp"`.
- **udev rules** at `/etc/udev/rules.d/99-qcom-ai.rules` document the
  device permissions. Nerves itself runs no udev (the app runs as root);
  they apply where udev rules are evaluated. fastrpc also installs
  `/lib/udev/rules.d/60-fastrpc.rules` and `/usr/lib/sysusers.d/fastrpc.conf`,
  equally inert here; `99-qcom-ai.rules` sorts later, so its `MODE="0666"`
  wins.

A build-time matched-pair check in `rubik-pi3-firmware.mk` fails the build
if the installed CDSP/ADSP `.mbn` and their fastrpc shells don't carry the
same `QC_IMAGE_VERSION_STRING`. A mismatch would otherwise only surface at
runtime as fastrpc error `0x80000600` with no kernel log.
