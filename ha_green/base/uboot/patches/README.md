# U-Boot patches

Home Assistant OS's patches for the Green, unmodified, applied in file-name
order on top of U-Boot v2026.04. They are what HAOS 18.4 builds its Green
U-Boot from, so this U-Boot differs from the stock one only in the config
fragment and the environment, never in C.

- Source: https://github.com/home-assistant/operating-system, tag `18.4`,
  commit `4a7dab478abc8f959c0fc2c24876d08282a3c060`
- Path: `buildroot-external/board/nabucasa/green/patches/uboot/`
- License: GPL-2.0-or-later (U-Boot's own license; these are patches to U-Boot
  carried by Home Assistant OS). The files they add say so in their SPDX
  headers, with two exceptions: `board/nabucasa/ha-green/ha-green.c` is
  `GPL-2.0` (only), and `arch/arm/dts/rk3566-ha-green.dts` is
  `(GPL-2.0+ OR MIT)`.

| sha256 | file |
| --- | --- |
| `f208b4c97192e009703c7d4c208565ec9dca6e3ba3437f1d4cd808d1507080f2` | `0001-arch-arm-dts-Add-NabuCasa-Green-board.patch` |
| `05772b398e1a3a0831ad568b499fdd4284f094b1eac3d3463499ab5fc8bd3ce8` | `0002-configs-green-Support-USB-boot.patch` |
| `a417085dc7d7fcfbbfbb3d8492962f9f2bb42f8121273725b527fa15607d3ce0` | `0003-arch-arm-dts-rk3566-green-boot-order.patch` |
| `bb39a771675e431f05634e2c17c5933d082ac776cbca214eee1fd17caac5acfc` | `0004-arch-arm-dts-green-spi-nor-uboot.patch` |
| `3eed61cb7fedef5cb89a6818fbc7ace1fb7341a9d4032a97931bd552b107bd19` | `0005-board-green-add-Green-board-to-read-board-specific-E.patch` |
| `87899182b1618106acad93e0ed618a0bb207d142bed710112ee353133192c2dd` | `0006-green-spl-loader-uboot-order-sd-emmc-spi_nor.patch` |
| `1d4166d334d39904657d6402e6873c3b985a4a2fe590cce33fa375da7c568e6e` | `0007-green-Fix-SPI-Flash-alias.patch` |
| `b3034ac16f5b5e9ea247f18030731ccf2c9f5a1a80ac1ea56d75e8d4a8d3e8cc` | `0008-arch-arm-dts-green-drop-SPI-NOR-flash-partitions.patch` |
| `15fa7885ee68318904a1874d78b7b8305e457c0596c8fb83e8268be185ac802d` | `0009-green-Do-not-use-eMMC-DDR52-mode-enable-HS200.patch` |
| `2c99674a46d6754cf10116148aaa691dc20c5caaca11e4a00ef983008e0d9781` | `0010-arch-arm64-dts-green-Improve-LED-representation.patch` |
| `03f4edded9540da5199b6f338ef1d97c4d5fbc2cff83da359f829dda880cf5a5` | `0011-configs-green-fix-bss-and-stack-address-and-disable-.patch` |

The files are byte-for-byte what is in the HAOS repository (git blob hashes
match GitHub's tree listing).
