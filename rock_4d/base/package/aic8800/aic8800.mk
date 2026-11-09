################################################################################
#
# aic8800 — AIC8800D80 USB WiFi/BT driver + firmware (ROCK 4D onboard module)
#
################################################################################

# Tag 5.0+git20260123.5f7be68d-10 (2026-10-12). 0001-0029 mirror the
# debian/patches from the same tag in series order; they carry
# kernel-version guards internally, so the full series is safe (and is
# exactly what Radxa's dkms deb applies on every kernel). Two of them
# (0006/0020) are regenerated with CRLF-correct context: some vendor
# sources are CRLF, upstream's patch contexts are LF, and GNU patch
# refuses the mismatch. Same changes, byte-exact context. Upstream
# patches that are themselves CRLF throughout (e.g. 0017) apply as-is:
# GNU patch strips their CRs. 0030 is fork-local (NUL-terminates the SDIO
# get_fw_path override copy) and is not in radxa-pkg's series.
AIC8800_VERSION = e9e43ed79c50483080e9bcdfb08caeeb869d7191
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
# The kernel modules declare MODULE_LICENSE("GPL") (GPL-2.0-or-later);
# radxa-pkg's repository-level LICENSE (their packaging) is GPL-3.0.
# The firmware blobs installed from fw/ are AICSemi proprietary,
# redistributed by Radxa.
AIC8800_LICENSE = GPL-2.0-or-later (modules), GPL-3.0 (packaging), proprietary (firmware)
AIC8800_LICENSE_FILES = LICENSE

# USB build only (the module is USB-attached; the SDIO/PCIE trees are for
# other boards). aic8800_fdrv links against symbols exported by aic_load_fw;
# depmod orders the autoload. Make invocation mirrors debian/aic8800-usb-dkms.dkms
# (no extra variables — the in-tree Makefile defaults select the USB build).
AIC8800_MODULE_SUBDIRS = \
	src/USB/driver_fw/drivers/aic8800 \
	src/USB/driver_fw/drivers/aic_btusb

# Firmware for the D80 only. Patch 0006 sets the
# /lib/firmware/aic8800_fw/USB prefix; the driver appends the per-chip
# aic8800D80 dir itself (chip-id dispatch under CONFIG_PLATFORM_UBUNTU,
# default y in the USB Makefiles).
define AIC8800_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800_fw/USB
	cp -a $(@D)/src/USB/driver_fw/fw/aic8800D80 \
		$(TARGET_DIR)/lib/firmware/aic8800_fw/USB/
endef

$(eval $(kernel-module))
$(eval $(generic-package))
