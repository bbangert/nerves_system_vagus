# U-Boot boot chain

The ROCK 4D boot ROM order is SPI NOR → UFS → USB (maskrom); it never
boots from SD. Every standard ROCK 4D has a 16 MB SPI NOR on board, so
U-Boot lives there and the UFS module only carries the Nerves environment,
kernels and root filesystems:

| Blob                      | Location                       | Contents                                                         |
| ------------------------- | ------------------------------ | ---------------------------------------------------------------- |
| `u-boot-rockchip-spi.bin` | SPI NOR, offset 0              | idblock (DDR init + SPL) + FIT (U-Boot proper + BL31) at 0x60000 |
| `uboot-env.bin`           | UFS LUN, start of GPT p1 `env` | Nerves environment (built from `uboot.env`)                      |

## Build

Buildroot builds `u-boot-rockchip-spi.bin` (`BR2_TARGET_UBOOT` in
`nerves_defconfig`) from mainline U-Boot v2027.01-rc1,
`rock-4d-rk3576_defconfig` plus `ufs.fragment`. binman packs the Rockchip
DDR-init TPL and BL31 from `rkbin/` (provenance and hashes in
`rkbin/README.md`). The result lands in the system's `images/` directory.

`ufs.fragment` adds:

- `ENV_IS_IN_SCSI` with `ENV_SCSI_PART_UUID`: U-Boot reads the env from the
  start of the GPT partition whose **unique** GUID matches. That GUID is
  `UBOOT_ENV_PART_GUID` in `fwup_include/fwup-common.conf`, p1's `guid`.
  `nerves_env_uuid` in `uboot.env` repeats it for the kernel loads. All
  three must be identical; `scripts/check-env-config.sh` runs from
  `post-build.sh` and fails the build if they are not. To change it, edit
  all three.
- `ENV_SIZE=0x20000`, which must equal `UBOOT_ENV_COUNT` × 512, the
  `uboot-env.bin` size and the `fw_env.config` size (all CRC `size - 4`
  bytes); `check-env-config.sh` enforces this too.
- `FS_FAT_HANDLE_SECTOR_SIZE_MISMATCH`: fwup can only make a 512-byte-BPB
  FAT, and U-Boot otherwise refuses it on the 4096-byte-sector LUN.
- SPI NOR vendor drivers (XMC, Macronix, GigaDevice, Winbond): the NOR part
  differs between board revisions.

The v0.1.x prebuilt image (env on SD) and its Docker build script live in
git history at tag v0.1.1.

Licensing: U-Boot is GPL-2.0-or-later (corresponding source: the pinned
tag at https://github.com/u-boot/u-boot). The DDR-init and BL31 components
in `u-boot-rockchip-spi.bin` and `rk3576_spl_loader_v1.09.108.bin` are
Rockchip proprietary blobs from
[rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin),
redistributable per `rkbin/LICENSE` (= `LICENSES/LICENSE.rockchip-rkbin`).

## Boot and automatic revert

U-Boot loads the env from p1 (the lookup runs `scsi scan`), then runs
`nerves_init`/`nerves_boot`: `nerves_find_disk` picks the SCSI device
whose p1 has `nerves_env_uuid` (default 0), then it loads the active
slot's `Image.<slot>` and dtb from that device's FAT bootfs (p2) and boots
them directly
(`root=PARTUUID=<slot GUID>`). Automatic revert follows the standard Nerves
model:

- U-Boot: with `nerves_fw_autovalidate=0`, new firmware boots once
  (`booted` 0→1) leaving `nerves_fw_validated=0`. If the next boot still
  sees `validated=0`, U-Boot boots the other slot.
- Application: calls `Nerves.Runtime.validate_firmware()` once healthy
  (sets `validated=1`), or the update reverts.

If `nerves_boot` ever fails, `bootcmd` falls through to `bootflow scan -lb`,
which boots `extlinux/extlinux.conf` from the bootfs. A missing or corrupt
environment block makes U-Boot fall back to its compiled-in default
environment, which does the same, so a bad environment cannot brick the
device. Both fallbacks depend on bootfs being the only partition marked
bootable: `bootflow scan` skips unbootable partitions (only p1, the raw
env, if none is marked). The env is a single copy (`env/scsi.c` has no
redundant mode): a torn `saveenv` costs the revert on that one boot.

## uboot.env: the shared firmware/boot environment

`uboot.env` is compiled into `uboot-env.bin` and written at the start of p1
(`UBOOT_ENV_OFFSET`, see `fwup_include/fwup-common.conf`).
`rootfs_overlay/etc/fw_env.config` reads it through the whole disk at
1 MiB, the same device fwup writes, because Linux caches `sda` and `sda1`
separately and a read through p1 could miss fwup's write. It is a single fw_env block shared by
three parties: U-Boot reads it to pick the boot slot, `nerves_runtime`/
`fwup` read and write the `nerves_fw_*` firmware metadata, and `boardid`
reads the serial number.

## Flashing the SPI NOR (one-time provisioning, via maskrom)

> **Remove the UFS module first** (or leave it in the USB reader). The
> maskrom loader (`rk3576_spl_loader_v1.09.108.bin` with `cs 9`) also
> re-provisions a seated UFS module and erases it: on a 128 GB module LUN0
> grew by 48 MiB, the boot LUNs folded into it, with an empty GPT and zeroed
> env and data. Reflash the module with `scripts/flash-ufs.sh` if that
> happened.

Flashing is done over USB from the host, with no OS on the board involved.
Hold the MASKROM button while applying power. The maskrom USB device
appears on the upper USB 3.0 Type-A OTG port (top-left, nearest the
corner); use a USB-A↔A or USB-A↔C data cable to the host. Then, with
`u-boot-rockchip-spi.bin` from the system's `images/` directory:

```sh
rkdeveloptool db uboot/rk3576_spl_loader_v1.09.108.bin  # bootstrap the loader
rkdeveloptool cs 9                                      # select the SPI NOR
rkdeveloptool wl 0 u-boot-rockchip-spi.bin              # write at offset 0
rkdeveloptool rd                                        # reboot
```

Verify on the serial console: the U-Boot banner should read
v2027.01-rc1.

`rk3576_spl_loader_v1.09.108.bin` is the RK3576 maskrom download loader,
built from the Rockchip vendor SDK's U-Boot (`./make.sh rk3576` packs it
from the rkbin SPL/DDR components). If `cs` is unsupported by your
rkdeveloptool build, use a current build from
https://github.com/rockchip-linux/rkdeveloptool or Rockchip's RKDevTool
on Windows.

Maskrom is also the recovery path if a NOR write is ever interrupted: the
BootROM always runs first, so the board is not brickable this way.

## Reflashing from a running system

The `-spi` device tree exposes the NOR as the `loader` MTD partition, and
the system ships `flashcp`:

```sh
grep loader /proc/mtd          # e.g. mtd0: 01000000 00001000 "loader"
flashcp -v u-boot-rockchip-spi.bin /dev/mtd0
```

Serial console for watching the boot: UART0 on the 40-pin header, pin 8
(TX), pin 10 (RX), pin 6 (GND), 1500000 8N1, no flow control.
