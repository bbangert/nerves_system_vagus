# Changelog

## 0.1.1

- The kernel's default cpufreq governor is `performance` and the RK809's own
  RTC driver is not built, matching the settings Home Assistant OS defines for
  this board. The CPU now holds its top frequency instead of following
  `schedutil`; the other governors remain selectable through sysfs. The
  PCF8563 is the only RTC (`rtc0`), so the unused `rtc1` alias is gone from the
  device tree. Run on one Home Assistant Green: the CPU stays at 1800 MHz, idle
  SoC temperature is unchanged within the sensor's 0.6 C step (about 33 C), and
  10 minutes of 4-core load held 44.4 C without throttling. Idle power was not
  measured.
- Documentation only: the NPU, Mali GPU, MPP codecs and RGA2 are recorded as
  verified from an app container (`rockchip_probe`), replacing "probe only".
  The RGA2 driver refused the tested user-memory buffers (it requires user
  memory to map as a single contiguous segment, which ordinary page-backed
  allocations do not) and accepted dma-bufs. The SoC's device tree must be
  visible to userspace for MPP and the RKNN runtime to initialise.

## 0.1.0

Initial system for the Home Assistant Green (RK3566). Run on one Home
Assistant Green (4 GiB RAM, 32 GB eMMC), from an SD card and installed to the
eMMC.

Verified on that unit:

- Boot chain: the unchanged factory first-stage loader takes `u-boot.itb`
  from the SD card when it carries our image, else from the eMMC; with our
  image on both, the card boots (rescue path).
- `green-install-emmc`: the loader area (LBA 64-16383) hash is identical
  before and after and equal to the factory value, the FIT window equals the
  source's, and fwup leaves the tool's GPT unchanged. The installer
  sizes the data partition to the whole disk; the first eMMC boot formats it,
  and the eMMC runs HS200.
- A/B on SD and eMMC: upgrade, validate, and revert of an unvalidated slot.
  A zeroed state block boots slot A on defaults and writes nothing back (SD).
- Restarts: `reboot`, kernel panic, watchdog reset and cold boot, each
  verified on SD and on eMMC; ten consecutive warm reboots all came back from
  the eMMC.
- Ethernet, both USB-A ports, RTC, hardware watchdog (`nerves_heart`), LEDs,
  CPU frequency scaling and thermal sensors, HDMI video with hot-unplug
  detection, and the board id from the EEPROM serial.
- Driver probe only, nothing run on them: NPU, Mali GPU, MPP video codecs,
  RGA, HDMI audio, DMA heaps.
- Not exercised: audio playback, a failed first power-up of a power domain,
  and a card without our image in the slot (covered only by the boot-script
  test matrix).

- Vendor kernel 6.1 (`rk-6.1-rkr7.2`) with a device tree for the Green and
  drivers for the NPU, Mali GPU, MPP video codecs, RGA and the PCF8563 RTC.
  Rockchip vendor storage, the SFC controller and SPI-NOR support are
  disabled, as are `/dev/mem` and the MMC test driver, so no driver can write
  the stock loader.
- The NPU's power domain is powered only after the RK809 has raised
  `vdd_npu` to 900 mV; the first SD boot panicked when the NPU's IOMMU
  probed with the rail still off. A power domain that fails its first
  power-up now fails the attaching device's probe instead of panicking the
  kernel.
- The SD card runs at 3.3 V high speed instead of UHS-I SDR104, with its
  supply and I/O rail always on. A `reboot` from SDR104 brought the unit up
  in stock Home Assistant OS: the card's shutdown had switched both rails
  off, the restart does not reset the PMIC, and the stock SPL skipped the
  card. A panic or watchdog reset would have left the card and its I/O
  rail at 1.8 V, a state that SPL is not built to boot from.
- All RAM above 4 GiB (256 MiB on a 4 GiB unit) is reserved `no-map` in the
  device tree and never used. The RGA2 core has no IOMMU and addresses only
  the first 4 GiB, and that RAM was the kernel's whole Normal zone, so
  ordinary dma-bufs landed there first and would have failed an RGA job.
  Every buffer is now addressable. The Rockchip dma-heap CMA, which sat in
  that RAM, is placed below 4 GiB. Measured on the unit: `/proc/iomem` lists
  System RAM as `00200000-efffffff` only, with `1f0000000-1ffffffff`
  reserved. The kernel uses the 3.75 GiB below 4 GiB; `MemTotal` is 3751128
  kB (about 3.58 GiB, was 4012756 kB) because of the kernel's own
  reservations. Both CMA pools are below 4 GiB: the default 128 MiB pool and
  the 32 MiB Rockchip dma-heap pool. GPU, NPU, MPP codecs and RGA2 probe as
  before, with the same device nodes. A/B upgrade and validate, `reboot`, and
  a kernel panic (crash log read from pstore) all passed on the eMMC with
  this map. No RGA job has been run, so RGA scaling itself is unproven. The
  hardware statements above predate this change.
- Soft lockups and RCU stalls panic, and so reboot, leaving a ramoops
  record; hung tasks are only logged.
- The board id, and so the hostname (`nerves-` plus the last four characters
  of the serial), is a provisioned `nerves_serial_number` or `serial_number`
  if set, else the EEPROM serial that U-Boot puts in the device tree, then
  the same serial from the U-Boot environment, then the SoC and MAC
  fallbacks. It was derived from the SoC ID because no U-Boot variable
  the config read exists.
- The SD card-detect pin is muxed as a plain GPIO rather than the
  `sdmmc0_det` function, which made the GPIO request warn at every boot.
- The unused legacy Mali-4xx driver and the RK817 battery and charger
  drivers (the Green has no battery) are no longer built.
- U-Boot v2026.04 with Home Assistant OS's Green patches, built as a FIT
  (`u-boot.itb`) only. The board's stock first-stage loader loads it from
  LBA 16384 of the SD card, else the eMMC. A compiled-in boot script picks
  the boot disk, handles the A/B state block, and shows its progress on the
  user LED and in breadcrumb files on the SD card's boot FAT.
- Disk layout and fwup tasks that never write eMMC LBA 64-16383 or the SPI
  NOR. `green-install-emmc` refuses unless the eMMC looks like a stock Green,
  writes the eMMC's partition table itself (fwup would rewrite LBA 0-255 with
  it), runs `fwup -t install`, and verifies that the loader area is unchanged
  and the FIT matches the SD card's. `expand-data` is SD-only; the eMMC's
  table is final at install.
- Build guards (`scripts/`) for the loader area, the FIT against the stock
  SPL's contract, the kernel config, env/layout consistency, GUID lookups
  and loader binaries, each with a failing test in `scripts/test-guards.sh`.
