################################################################################
#
# aic8800
#
# Out-of-tree driver for the Q6A's onboard AIC8800D80 WiFi 6 + BT 5.4
# module (Quectel FCU760K, USB a69c:8d80), from Radxa's official
# packaging of the Aicsemi vendor SDK. Pinned to the commit that ships
# deb release 5.0+git20260123.5f7be68d-7 (includes the "Fix Linux 7.1
# build" commit and the 6.12+ cfg80211 API fixes). Keep in lockstep
# with package/aic8800-firmware (same repo, same commit).
#
# Builds THREE modules, mirroring upstream's debian/aic8800-usb-dkms.dkms
# exactly (two kbuild dirs):
#
#   drivers/aic8800  -> aic_load_fw.ko  (firmware loader / BSP)
#                       aic8800_fdrv.ko (cfg80211 fullmac WiFi -> wlan0)
#   drivers/aic_btusb-> aic_btusb.ko    (BT USB -> hci0, after flip below)
#
# DEBIAN PATCH SERIES (first POST_PATCH hook): the raw GitHub tree is
# the untouched Aicsemi SDK drop -- ALL of Radxa's kernel-compat work
# (fix-linux-6.1 ... fix-linux-7.1-build.patch) and misc build fixes
# live only in debian/patches/ and are applied by dpkg-source when
# Radxa builds their DKMS debs. Building the raw tree against kernel
# 7.1 fails with cfg80211 API errors (verified 2026-07-25). So we
# replay the quilt series in series-file order -- the source state the
# vendor-tested debs are built from -- EXCEPT two patches whose USB
# hunks cannot apply with GNU patch because the SDK V5.0 drop gave
# those .c files CRLF line endings while the patches are LF
# (verified against 5f7be68d-7; both are non-essential):
#
#   fix-usb-firmware-path.patch      -- only moves the firmware base
#     dir to /lib/firmware/aic8800_fw/USB for Radxa's deb layout;
#     skipping keeps the driver default /lib/firmware, and
#     package/aic8800-firmware installs to the matching
#     /lib/firmware/aic8800D80/ (chip subdir appended by the loader).
#     NEVER half-apply this patch: its aic_btusb.c hunk applies while
#     its aicbluetooth.c hunk rejects, which would split the WiFi/BT
#     halves across two different firmware dirs.
#   fix-Lower-the-debugging-log-level.patch -- cosmetic dmesg
#     verbosity reduction (LOGERROR-only); vendor default log level
#     stays, which is noisier but harmless.
#
# Re-check both skips on every version bump: if upstream refreshes
# them (or normalizes line endings), prefer dropping the skip over
# carrying it.
#
# CONFIG_BLUEDROID flip (POST_PATCH hook): the vendor source hardcodes
# CONFIG_BLUEDROID=1 in aic_btusb.h, which exposes an Android-HAL char
# device (/dev/aicbt_dev) instead of registering a BlueZ HCI -- this is
# the root cause of every public "AIC8800 BT doesn't work on Linux"
# report. With 0, the driver calls hci_register_dev() and a standard
# hci0 appears for bluetoothd. Radxa themselves ship this exact flip as
# a debian-only patch (debian/patches/fix-aic_btusb-use-bluez-by-default
# .patch, in the series above) -- but their patch only flips the
# CONFIG_PLATFORM_UBUNTU branch, so after the series we sed the
# remaining branch(es) to 0 as well and guard both directions: the
# build fails loudly if an upstream rename ever makes the flip a
# silent no-op.
#
# BLE ADVERTISING NOTE (no driver patch needed, but read this before
# adding one): BlueZ advertising on this chip looked completely dead
# until the advertising interval was lowered -- see
# ../../rootfs_overlay/etc/bluetooth/main.conf. At the kernel default
# (1280 ms) combined with BlueZ's instance rotation, effectively no
# advertising events reached the air even though every HCI command
# returned status 0x00. The parked patch here
# (0001-...-mask-broken-ext-adv-feature.patch.disabled) was an earlier
# attempt to force legacy advertising; it is NOT applied, because
# masking only the ext-adv feature bit leaves the kernel using
# EXTENDED scan/connect commands (those key off the supported-commands
# bitmap instead) and that mix kills LE scanning on this firmware.
#
# ARMBIAN-TRACKING RULE (see the WiFi/Bluetooth section of ../../README.md):
# on every kernel bump, check radxa-pkg/aic8800 for kernel-API fixes and
# Armbian's extensions/radxa-aic8800.sh DKMS version guard -- but never
# "sync" this package to Armbian's extension blindly: Armbian compiles
# the source UNFLIPPED (Bluedroid mode, no working BlueZ BT).
#
################################################################################

AIC8800_VERSION = 6e076049b719ac2ff7ce5c92786a680407b11cdb
AIC8800_SITE = $(call github,radxa-pkg,aic8800,$(AIC8800_VERSION))
AIC8800_LICENSE = GPL-2.0 (driver source), GPL-3.0+ (packaging)
AIC8800_LICENSE_FILES = LICENSE debian/copyright

AIC8800_MODULE_SUBDIRS = \
	src/USB/driver_fw/drivers/aic8800 \
	src/USB/driver_fw/drivers/aic_btusb

AIC8800_BTUSB_H = src/USB/driver_fw/drivers/aic_btusb/aic_btusb.h

# Replay Radxa's quilt series in series-file order (order matters: the
# kernel-compat patches build on one another; alphabetical APPLY_PATCHES
# would misorder them). Skips per the header comment; -f so a partial
# apply can never be mistaken for success.
define AIC8800_APPLY_DEBIAN_PATCH_SERIES
	cd $(@D) && while read -r p; do \
		case "$$p" in ""|\#*) continue ;; \
			fix-usb-firmware-path.patch|fix-Lower-the-debugging-log-level.patch) \
				echo "aic8800: skipping $$p (CRLF-incompatible, see aic8800.mk)"; continue ;; \
		esac; \
		patch -p1 --no-backup-if-mismatch -s -f < debian/patches/$$p \
			|| { echo "aic8800: debian patch $$p failed to apply"; exit 1; }; \
	done < debian/patches/series
endef
AIC8800_POST_PATCH_HOOKS += AIC8800_APPLY_DEBIAN_PATCH_SERIES

define AIC8800_FLIP_BLUEDROID_TO_BLUEZ
	$(SED) 's/^#define CONFIG_BLUEDROID\([[:space:]]*\)1/#define CONFIG_BLUEDROID\10/' \
		$(@D)/$(AIC8800_BTUSB_H)
	grep -q '^#define CONFIG_BLUEDROID[[:space:]]*0' $(@D)/$(AIC8800_BTUSB_H)
	! grep -q '^#define CONFIG_BLUEDROID[[:space:]]*1' $(@D)/$(AIC8800_BTUSB_H)
endef
AIC8800_POST_PATCH_HOOKS += AIC8800_FLIP_BLUEDROID_TO_BLUEZ

$(eval $(kernel-module))
$(eval $(generic-package))
