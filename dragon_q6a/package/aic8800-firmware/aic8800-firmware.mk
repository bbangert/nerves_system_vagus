################################################################################
#
# aic8800-firmware
#
# Firmware blobs for the AIC8800D80 USB WiFi+BT chip, from the same
# radxa-pkg/aic8800 tree as package/aic8800 -- keep the two version
# pins in lockstep (driver and firmware come from one vendor SDK drop;
# skew between them is untested territory).
#
# Install path is the one the driver actually opens (aic_load_fw/
# aicbluetooth.c): with CONFIG_PLATFORM_UBUNTU (the default in all
# three module Makefiles) and no aic_fw_path= module parameter, a
# D80-chipid device loads "/lib/firmware/aic8800D80/<name>". Radxa's
# own deb uses /lib/firmware/aic8800_fw/USB/... instead, but ONLY
# because their fix-usb-firmware-path.patch rewrites the driver's
# base path -- package/aic8800 deliberately SKIPS that patch (CRLF
# breakage, see aic8800.mk), so the driver default applies here. If
# the driver package ever applies it, this path must move to
# /lib/firmware/aic8800_fw/USB/aic8800D80/ -- the two packages move
# together.
#
# The whole fw/aic8800D80/ directory is installed rather than a
# hand-picked file list: the loader selects u02 vs u04 patch sets (and
# lmac/calib variants) by chip revision at RUNTIME, and also reads the
# aic_userconfig/aic_powerlimit txt files and the BLE scan filter
# table. Cherry-picking risks a probe-time "file not found" only
# reproducible on specific silicon revisions.
#
# The blobs are proprietary Aicsemi binaries, publicly redistributed by
# Radxa in their GPL-wrapped packaging (debian/copyright labels the src
# tree; the binaries carry no standalone license text).
#
################################################################################

AIC8800_FIRMWARE_VERSION = 6e076049b719ac2ff7ce5c92786a680407b11cdb
AIC8800_FIRMWARE_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_FIRMWARE_VERSION))
AIC8800_FIRMWARE_LICENSE = PROPRIETARY (Aicsemi firmware, redistributed by radxa-pkg)
AIC8800_FIRMWARE_LICENSE_FILES = LICENSE debian/copyright
# NO, matching package/dragon-q6a-firmware: this keeps the tarball out of
# `make legal-info` source dumps. The blobs carry no standalone license
# text -- all that is actually established is that Radxa publish them in a
# public GPL-3.0 repo and ship them in their own images, which is not an
# explicit redistribution grant (see the licensing note in the vagus repo's
# plan research). package/aic8800 sets the same, because it downloads the
# SAME tarball: leaving that one at the default YES would put the identical
# bytes into a legal-info dump through the other package and make this
# setting pointless.
AIC8800_FIRMWARE_REDISTRIBUTE = NO

AIC8800_FIRMWARE_D80_DIR = src/USB/driver_fw/fw/aic8800D80

define AIC8800_FIRMWARE_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800D80
	$(INSTALL) -m 0644 $(@D)/$(AIC8800_FIRMWARE_D80_DIR)/* \
		$(TARGET_DIR)/lib/firmware/aic8800D80/
endef

$(eval $(generic-package))
