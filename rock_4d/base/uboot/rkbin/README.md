# Rockchip rkbin blobs

The RK3576 DDR-init TPL and BL31 that U-Boot's binman packs into
`u-boot-rockchip-spi.bin`.

Source: https://github.com/rockchip-linux/rkbin. BL31 and `LICENSE` are from
commit `ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4`, the pair the v0.1.x SPI
image was proven with. The DDR blob is v1.13 from commit
`14ece058efc139853642663800d86ed468923115`: v1.12 lacks "add adaptation to 2
cs ddr if cs at high position and row_3_4 is enabled", and a 6 GB ROCK 4D
(row_3_4, second CS high) only booted with the kernel limited to the low
2.75 GB on it. License: `LICENSE` (also `LICENSES/LICENSE.rockchip-rkbin`).

| File | rkbin path | sha256 |
| --- | --- | --- |
| `rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.13.bin` | `bin/rk35/rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.13.bin` | `f697151bdd09d31bf7a1e49d63796a6a200e81bf8f9a766c2e95c840e88fc0ce` |
| `rk3576_bl31_v1.24.elf` | `bin/rk35/rk3576_bl31_v1.24.elf` | `e2cf4e0e920dfe1daa6412c05f49dc7e5c0f9888d3a3e8eecc85fbe1e86a23d1` |
| `LICENSE` | `LICENSE` | `d2765124a2c24d71aba3cbc6cdd6975a5a297821264eb6c26378a4c16cd16e92` |
