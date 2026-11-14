# U-Boot

Boot chain:

1. BootROM → the board's stock first stage. Read out of one unit running stock Home Assistant OS 18.4: the SPI NOR holds `U-Boot SPL 2023.07.02`, the eMMC (LBA 64–16383) `U-Boot SPL 2026.04`, and both SPLs' device trees carry the boot order SD card → eMMC → SPI NOR (`u-boot,spl-boot-order`). Which of the two the BootROM runs is inferred (no `u-boot,spl-boot-device` in `/chosen`, which a 2026.04 SPL would set), not proven; neither is ever written by us.
2. Either SPL loads our `u-boot.itb` from raw LBA 16384 of the SD card if it carries FDT magic there, else of the eMMC.
3. Our U-Boot runs the boot script below and boots `Image.<slot>` with `booti`.

U-Boot proper is v2026.04 plus Home Assistant OS's Green patches
(`patches/`, unmodified, so no C of ours), `green_defconfig` and
`green.fragment`. The whole default environment, and so the whole boot
logic, is `uboot.env`, compiled in through `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE`
(without it the board would silently run `bootflow scan`). Only `u-boot.itb`
is installed.

The stock SPL accepts only a FIT of a certain shape:
uncompressed images, sha256 hashes, `firmware = "atf-1"`. `stock-fit-contract.txt`
is that shape, derived from the FIT in Home Assistant OS 18.4's Green image,
and `scripts/check-fit.sh` holds every build to it, together with the
U-Boot config options behind it (`SPL_FIT_SIGNATURE=y`, `SPL_SHA256=y`, no
`SPL_GZIP`/`SPL_LZMA`/`ENV_REDUNDANT`/`CMD_SF`, `ENV_IS_NOWHERE=y`,
`ENV_SIZE=0x20000`).

## Boot script

There is no console, so the script never stops at a prompt, and its only
outputs are an LED, files on the SD card, and whether Linux comes up.
`scripts/test-boot-script.sh` runs this exact file in U-Boot's sandbox
against two disk images and checks every case below.

1. **Boot disk.** If the control FDT's `/chosen/u-boot,spl-boot-device`
   (set by a 2026.04 SPL: the ofpath of the controller it loaded U-Boot
   from) is exactly `/mmc@fe2b0000`, the SD card (`mmc 1`, unless
   `mmc dev 1` fails); exactly `/mmc@fe310000`, the eMMC (`mmc 0`). Any
   other value, or none, leaves it to the probe, the SPL's own rule: the SD
   card iff it reads and holds FDT magic at LBA 0x4000, otherwise the eMMC.
   The older SPL in the NOR sets no such property, so on units where it
   runs the probe decides, and a card whose FIT still has its magic but was
   rejected by the SPL (which then loaded the eMMC's) is still taken as the
   boot disk: remove the card to boot the eMMC. Read before the import and
   kept in the snapshot with the script's own variables. Nothing is looked
   up by GUID or name.
2. **State.** 256 blocks at LBA 0x8000 of the boot disk (the first
   128 KiB of p1, what `fw_env.config` and fwup address) are imported with
   `env import -c`. A missing, corrupt or foreign block fails its CRC, and
   the boot goes on with the compiled-in defaults: slot A, validated.
   The script's own variables (the list in `nerves_owned`, which also
   holds the step 1 results) and the values
   U-Boot computed this boot (`ver`, `fdtcontroladdr`, `serial#`,
   `ethaddr`, `nerves_disk`, `nerves_state`) are copied to RAM before the
   import and put back from that copy after it. **Invariant: after an import
   the script acts on no variable until those variables are shown to
   equal the copy (re-exported and compared byte for byte; a changed name
   list changes the export too); if they do not, or
   the import failed even part-way (an empty key), the whole environment
   is reset to the compiled-in one plus the copy, which is exactly a boot
   without a block.** Until then the script uses only literal addresses.
   So neither an older export nor a malformed block can change the disk,
   the script, or, unless it imports cleanly, the slot.
   **Invariant: no flag or callback binding from a block ever constrains
   the script.** A block that still declares `.flags` or `.callbacks`
   after its import counts as absent, so U-Boot never rewrites it either
   (after a `fw_setenv .flags …` the board boots slot A with the
   defaults). Every other block is rebuilt before use, from its own binary
   export (a text one does not escape newlines in names) on top of the
   compiled-in environment, which drops any binding it left
   behind by rebinding and deleting those two, and brings back with its
   default any compiled-in variable it deleted. Every variable the script
   sets from here on is compiled in (`bootargs` and `filesize` too) and,
   except the Nerves state, in `nerves_owned`, so setting it only overwrites and cannot fail, not even
   when a block fills U-Boot's 521-entry variable table.
3. **A/B,** the Nerves rule: the first boot of a slot sets
   `nerves_fw_booted=1`; a slot that boots again with
   `nerves_fw_validated=0` is reverted (`nerves_fw_active` flips,
   `nerves_fw_validated=1`). `nerves_fw_autovalidate=1` validates on first
   boot.
4. **Save.** The only raw write U-Boot makes: `env export -c` of the whole
   environment to LBA 0x8000 of the boot disk, only when step 3 changed
   something and only if the block from that same disk counted in this
   boot. **A disk without our valid state block is never written by
   U-Boot**; this is what keeps a stock eMMC untouched while the system
   runs from SD. U-Boot cannot hold an empty value, so a key fwup wrote as
   `""` is gone from the block after a U-Boot save (as on every Nerves
   board).
5. **Kernel.** `Image.<slot>` and `rk3566-ha-green.<slot>.dtb` from
   `mmc <disk>:2`; `root=/dev/mmcblk<disk>p<3|4> rootfstype=squashfs
   rootwait console=ttyS2,1500000n8 console=tty0`, then
   `uboot.boot_disk=mmcblk<disk>`, `uboot.boot_disk_by=spl|probe` (which
   rule of step 1 chose it), `uboot.sd_fit=present|absent` (the probe's
   finding, so `mmcblk0` by `spl` with `present` is an SD FIT the SPL
   passed over) and `uboot.version=<ver>` (spaces and parentheses replaced
   by `_`), then `${cmdline}` (empty; settable with `fw_setenv`). Linux
   ignores the `uboot.*` parameters; read them from `/proc/cmdline`.
6. **Failure.** If a load or `booti` fails, or the command line could not
   be set or does not start with this boot's `root=` (a `cmdline` of more
   than 53 words, for one): user LED off, 10 s pause (so a
   persistent failure does not hammer the disks), `reset`.

LED code (user LED): solid from the first line of the script; off for
10 s before each retry when U-Boot cannot boot; heartbeat once the kernel
runs (kernel DTS).

### Breadcrumbs

Only when the boot disk is the SD card, on its FAT partition (`mmc 1:2`,
a literal, so they can never land on the eMMC). Fixed names, and each is
written only if it differs from the copy already on the card, so
steady-state boots and retry loops write nothing:

| File | Content |
| --- | --- |
| `uboot-vars.txt` | boot disk, state result, slot, A/B variables, `nerves_spl_boot_device` (`/chosen/u-boot,spl-boot-device`, `absent`, or `empty`), `nerves_disk_by` (`spl` or `probe`), `nerves_sd_fit`, `serial#`, `ethaddr`, `ver`, `bootargs` |
| `uboot-fdt.dtb` | U-Boot's control FDT as the SPL handed it over (`dtc -I dtb` shows every `/chosen` property) |
| `ramoops.bin` | RAM 0x110000–0x1fffff, the kernel's ramoops region, only if a kernel left its signature there: the previous boot's console log, when RAM survived the reset |

### Watchdog

Off by default; `fw_setenv nerves_watchdog 1` turns it on. The script then
starts the SoC watchdog (dw-wdt, 0xfe600000) just before `booti` with its
longest timeout, 2^31 cycles of 24 MHz (about 89 s), reset on first
expiry, so a hung kernel resets and the next SD boot saves its ramoops
log. These are plain register writes: U-Boot's driver cannot probe on
RK3568 (the clock driver has no enable op). Once started the dw-wdt only
stops on reset, so turn it on only after Linux is seen to take it over
(`dw_wdt` built in, `WATCHDOG_HANDLE_BOOT_ENABLED=y`, then `heart`);
otherwise the board resets about 89 s into every boot.

## Configuration delta

Every Kconfig difference between the U-Boot this system builds and the
reference it starts from: `green_defconfig` plus HAOS's own fragments
(`bootloader/uboot.config` and `board/nabucasa/green/uboot.config` in
home-assistant/operating-system 18.4), merged the way Buildroot does. Both
sides leave out `CMD_FILEENV`; HAOS's build additionally carries the C patch
for it, which this system does not need.

| Option | HAOS reference | Here | Why |
| --- | --- | --- | --- |
| `CONFIG_ENV_SIZE` | `0x1f000` | `0x20000` | The state block is 128 KiB in fwup, `fw_env.config` and the env image; U-Boot and fwup both CRC size minus 4 bytes. |
| `CONFIG_CMD_SF` (and `_TEST`) | `y` | not set | No `sf` command: the SPI NOR holds the factory loader and must never be written. |
| `CONFIG_ENV_USE_DEFAULT_ENV_TEXT_FILE`, `CONFIG_ENV_DEFAULT_ENV_TEXT_FILE` | not set | `y`, `uboot/uboot.env` | The compiled-in environment is the boot script. Buildroot sets both from `BR2_TARGET_UBOOT_DEFAULT_ENV_FILE`. |
| `CONFIG_BOOTCOMMAND` | `"bootflow scan -lb"` | gone | Kconfig drops it once the environment comes from a text file; `bootcmd` is in `uboot.env`. |
| `CONFIG_VERSION_VARIABLE` | not set | `y` | Provides `ver`, which goes on the kernel command line and into the breadcrumbs. |
| `CONFIG_SYS_PROMPT` | `"HAOS> "` | `"=> "` | `green.fragment` does not carry HAOS's prompt; there is no console, so it is never seen. |
| `CONFIG_GCC_VERSION` and the compiler banner | host GCC 15.2.0 | Nerves toolchain GCC 15.3.0 | Build environment only. |

To reproduce, from an unpacked U-Boot v2026.04 with `patches/*.patch`
applied (`$O` outputs are separate directories):

```sh
make O=$PWD/../ours green_defconfig
printf 'CONFIG_ENV_USE_DEFAULT_ENV_TEXT_FILE=y\nCONFIG_ENV_DEFAULT_ENV_TEXT_FILE="%s"\n' "$REPO/uboot/uboot.env" >../ours.fragment
scripts/kconfig/merge_config.sh -m -O ../ours ../ours/.config "$REPO/uboot/green.fragment" ../ours.fragment && make O=$PWD/../ours olddefconfig
# the reference: the same, merging HAOS's two fragments (minus CMD_FILEENV) instead
diff ../haos/.config ../ours/.config
```

Inside a build, ours is `build/uboot-custom/.config` of the Buildroot output.
