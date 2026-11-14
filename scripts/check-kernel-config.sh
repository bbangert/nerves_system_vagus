#!/bin/sh
#
# Checks the merged kernel .config. Rockchip vendor storage writes eMMC LBA
# 7168-7679 (inside the stock loader area, e.g. a random MAC from dwmac-rk),
# and the SFC/SPI-NOR drivers would expose the factory loader in the NOR, so
# none of them may be enabled. /dev/mem would let root program the unclaimed
# SFC through its MMIO, and mmc_test writes raw test patterns to whatever
# card it binds. The other options are what the planned accelerator, RTC and
# ramoops/watchdog/lockup diagnostics depend on.
#
# Usage: check-kernel-config.sh <kernel .config>

set -e

CONFIG=${1:?usage: check-kernel-config.sh <kernel .config>}
[ -r "$CONFIG" ] || { echo "check-kernel-config: cannot read $CONFIG" >&2; exit 2; }

rc=0
for sym in ROCKCHIP_VENDOR_STORAGE ROCKCHIP_MMC_VENDOR_STORAGE \
    ROCKCHIP_VENDOR_STORAGE_UPDATE_LOADER SPI_ROCKCHIP_SFC MTD_SPI_NOR \
    FIQ_DEBUGGER DEVMEM MMC_TEST; do
    if grep -q "^CONFIG_${sym}=[ym]" "$CONFIG"; then
        echo "check-kernel-config: FAIL CONFIG_$sym is enabled in $CONFIG; it can write the stock loader area or the SPI NOR" >&2
        rc=1
    fi
done
for sym in MALI_BIFROST ROCKCHIP_RKNPU ROCKCHIP_MPP_SERVICE RTC_DRV_PCF8563 \
    PSTORE_RAM PSTORE_CONSOLE DW_WATCHDOG SOFTLOCKUP_DETECTOR \
    BOOTPARAM_SOFTLOCKUP_PANIC DETECT_HUNG_TASK BOOTPARAM_RCU_STALL_PANIC; do
    if ! grep -q "^CONFIG_${sym}=y" "$CONFIG"; then
        echo "check-kernel-config: FAIL CONFIG_$sym is not =y in $CONFIG" >&2
        rc=1
    fi
done
[ "$rc" -eq 0 ] && echo "check-kernel-config: OK $CONFIG"
exit "$rc"
