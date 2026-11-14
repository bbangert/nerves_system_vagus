# Rockchip rkbin blobs

RK3566 DDR-init TPL and RK3568 BL31 for U-Boot's binman. The BL31 goes into
`u-boot.itb`. The DDR blob is present only because binman refuses to finish
without a TPL: it ends up in an `idbloader.img` that is never installed, since
the board's stock first-stage loader does its own DDR init.

Source: https://github.com/rockchip-linux/rkbin, commit
`b4558da0860ca48bf1a571dd33ccba580b9abe23` (2023-07-26), the revision and
paths Home Assistant OS 18.4 builds its Green U-Boot with. License:
`LICENSE` (also `LICENSES/LICENSE.rockchip-rkbin`), the repository's license
text at that commit, verbatim.

| File | rkbin path | sha256 |
| --- | --- | --- |
| `rk3566_ddr_1056MHz_v1.18.bin` | `bin/rk35/rk3566_ddr_1056MHz_v1.18.bin` | `dc006356ae0d1d1f66858a3762e6f5a5294caee1ca173ee5b0c4531bd4208d4f` |
| `rk3568_bl31_v1.43.elf` | `bin/rk35/rk3568_bl31_v1.43.elf` | `53b9371beeaa0c6a3c0235a0f069adc719ff9028a7863772ce5eef24156ab07c` |
| `LICENSE` | `LICENSE` | `1f2e25ae65f3af774e6f141f84253d6a05d489fb0b88b311220d70471c023c9c` |
