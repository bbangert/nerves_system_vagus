# Rockchip rkbin blobs

The RK3576 DDR-init TPL and BL31 that U-Boot's binman packs into
`u-boot-rockchip-spi.bin`. They are the same pair the v0.1.x SPI image was
built and hardware-proven with.

Source: https://github.com/rockchip-linux/rkbin at commit
`ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4`. License: `LICENSE` (copied from
that commit; also `LICENSES/LICENSE.rockchip-rkbin`).

| File | rkbin path | sha256 |
| --- | --- | --- |
| `rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin` | `bin/rk35/rk3576_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin` | `17f54933f87d22f72a7c7c548b1d0c79cf804824064c626be25d42d6863b831f` |
| `rk3576_bl31_v1.24.elf` | `bin/rk35/rk3576_bl31_v1.24.elf` | `e2cf4e0e920dfe1daa6412c05f49dc7e5c0f9888d3a3e8eecc85fbe1e86a23d1` |
| `LICENSE` | `LICENSE` | `d2765124a2c24d71aba3cbc6cdd6975a5a297821264eb6c26378a4c16cd16e92` |
