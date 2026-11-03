# AI foundation contract

What this system guarantees to applications (device validation is recorded
per component in [validation.md](validation.md)):

- **Kernel**: `QCOM_FASTRPC` built in; `/dev/fastrpc-adsp`,
  `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` present; DMA-BUF system
  heap at `/dev/dma_heap/system`; two Venus nodes, a decoder and an
  encoder, at `/dev/video0` and `/dev/video1`. Which is which follows
  module load order and was observed both ways (`video0` = decoder on
  kernel 7.1.4, `video0` = encoder on 7.2.10), so identify them by
  `/sys/class/video4linux/*/name`: `qcom-venus-decoder` /
  `qcom-venus-encoder`.
- **Firmware** (`/lib/firmware/qcom/...`): matched CDSP set (c3 line, see
  [validation.md](validation.md)), board ADSP set with `.jsn` fastrpc domain descriptors, Adreno
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
  kernel 7.1.4; see [validation.md](validation.md) for the shipped pin.
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
