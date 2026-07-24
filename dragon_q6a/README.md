# Radxa Dragon Q6A (QCS6490)

This is the Nerves System configuration for the Radxa Dragon Q6A.

| Feature        | Description                                    |
| -------------- | ---------------------------------------------- |
| CPU            | QCS6490 (4x Cortex-A78 + 4x Cortex-A55)        |
| Memory         | 4/8/16 GB LPDDR4x                              |
| Storage        | NVMe (M.2), UFS variant planned                |
| Ethernet       | RTL8125 2.5 GbE (r8169 driver)                 |
| GPU            | Adreno 643 (drm/msm)                           |
| Video          | Venus V4L2 encode/decode                       |
| NPU/DSP        | Hexagon CDSP/ADSP via fastrpc                  |
| Boot           | EDK2 UEFI (SPI NOR) → GRUB2 arm64-efi → A/B    |

README content (board overview, flashing runbook, AI-foundation contract,
UFS variant status) is completed as part of the release phase — see
`docs/dragon-q6a-flashing.md` in the repo root for EDL flashing.

## DSP daemon supervision (deliberate non-decision)

The system SHIPS the fastrpc daemons (`adsprpcd`, `cdsprpcd`) and their DSP
payloads but does NOT start or supervise them — there is no init system on
Nerves and no system-level supervisor for them by design. Supervision is
app-level: start them from your OTP application (e.g. with
[MuonTrap](https://hex.pm/packages/muontrap)) so restarts, backoff, and
shutdown ride the app's supervision tree.

Manual start (what the Phase-3 smoke tests do):

```sh
# CDSP (compute; domain 3). Shells/skels: /usr/lib/dsp/cdsp
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" cdsprpcd &

# ADSP (audio; domain 0). Shells/modules: /usr/lib/dsp/adsp
ADSP_LIBRARY_PATH="/usr/lib/dsp/adsp;" adsprpcd &

# Then, e.g.:
DSP_LIBRARY_PATH="/usr/lib/dsp/cdsp;" fastrpc_test -a v68
```

The per-domain directories exist because the ADSP and CDSP shell sets carry
identically-named sysmon skels; fastrpc's built-in search path
(`/usr/lib/rfsa/adsp;/usr/lib/dsp`) is not used for that reason. The
CDSP firmware (`/lib/firmware/qcom/qcs6490/cdsp.mbn`) and the shells in
`/usr/lib/dsp/cdsp` are a MATCHED PAIR (`CDSP.HT.2.5.c4-00004-KODIAK-1`) —
never mix sources; a mismatch fails with fastrpc error `0x80000600`. See
`package/dragon-q6a-firmware/dragon-q6a-firmware.mk` for provenance.
