################################################################################
#
# rubik-pi3-firmware
#
# Firmware for the Thundercomm Rubik Pi 3 (QCS6490). Three sources:
#
# 1. Upstream linux-firmware (the same tarball Buildroot's linux-firmware
#    package downloads -- this package DEPENDS on it and copies files
#    straight out of its extracted source tree instead of fetching a second
#    450 MB copy). File paths below are the REAL files; the qcom/qcs6490/*
#    names the kernel requests are WHENCE symlinks materialized only at
#    linux-firmware's own install step, so we install to the requested path
#    explicitly.
#
# 2. linux-msm/hexagon-dsp-binaries (this package's main download) for the
#    DSP-side shell/skel binaries that fastrpc loads into the CDSP/ADSP.
#
# 3. The Broadcom blobs for the onboard AMPAK AP6256 (BCM43456-class) WiFi/BT
#    module, fetched as _EXTRA_DOWNLOADS from two pinned vendor commits --
#    linux-firmware carries no brcmfmac43456 firmware and no BCM4345C5
#    patchram at all (checked against linux-firmware 20260410: only the
#    43455/cyfmac43455 set is there). See the AP6256 section below.
#
# FIRMWARE PATHS COME FROM THE DTB WE ACTUALLY BOOT: grub.cfg loads the
# mainline in-tree qcs6490-thundercomm-rubikpi3.dtb explicitly, so the
# `firmware-name` properties of that DTS are what the kernel requests:
#
#   &remoteproc_adsp  qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn
#   &remoteproc_cdsp  qcom/qcs6490/cdsp.mbn        (generic, no board dir)
#   &gpu zap          qcom/qcs6490/a660_zap.mbn
#   &qupv3_id_0/1     qcom/qcm6490/qupv3fw.elf
#
# On DTB-load failure GRUB falls back to the EDK2 firmware DT, which may ask
# for different board paths (that is exactly what happened on the Q6A). Only
# the mainline paths are installed here; if the fallback path ever has to
# work for DSP too, add the board-path duplicates then.
#
# MATCHED-PAIR RULE (do not break; failure mode is fastrpc error
# 0x80000600 with no kernel log): each .mbn the kernel loads and the
# fastrpc_shell_* binaries for that domain must carry the same
# QC_IMAGE_VERSION_STRING (the shell dir is named after it).
#
# ADSP pair: hexagon-dsp-binaries ships a RubikPi3 board dir whose single
# shell set matches the linux-firmware RubikPi3 adsp.mbn exactly --
#
#   qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn = ADSP.HT.5.5.c8-00217-KODIAK-1
#   qcs6490/Thundercomm/RubikPi3/ADSP.HT.5.5.c8-00217-KODIAK-1/  (shells)
#
# CDSP pair: the DTS asks for the GENERIC image, and there is no RubikPi3
# CDSP dir upstream, so this is the generic c3 line the Q6A bring-up proved
# on a mainline kernel --
#
#   qcom/qcm6490/cdsp.mbn = CDSP.HT.2.5.c3-00134-KODIAK-1
#   qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1/   (shells)
#
# Both pairings are re-tested on the board at plan task 3.6 (nothing here is
# device-proven on Rubik Pi 3 yet). Known fallback if fastrpc misbehaves:
# swap the CDSP pair to another c3-00xxx version in the RB3gen2 dir, or the
# ADSP pair to one of the RB3gen2 ADSP.HT.5.5.c8-* sets -- always moving the
# .mbn and the shell dir together.
#
# ---- AP6256 WiFi/BT blobs -------------------------------------------------
#
# WiFi (brcmfmac on SDIO behind &sdhc_2). The .bin/.clm_blob come from
# armbian/firmware, which is the de-facto distribution point for the
# brcmfmac43456 FullMAC firmware (the blob's own version string reads
# "43455c5-roml ... Version: 7.45.96.0" -- BCM43456 and BCM43455 are the same
# CYW4345 C5 die, 43456 is just the chiprev name brcmfmac derives; this is
# the same file Radxa/RPi-400 boards use).
#
# NVRAM comes from the BOARD VENDOR's own firmware package, which is the
# authority for this module's calibration/xtal values. Note the file is
# BYTE-IDENTICAL (sha256 588430b4...) to armbian's brcm/nvram_ap6256.txt, so
# it is fetched from armbian for a self-describing download name and to keep
# the WiFi blobs on one pinned commit. Vendor path for the record:
# rubikpi-ai/rubikpi3-firmware lib/firmware/nvram.txt (their bcmdhd layout).
#
# It is installed under BOTH names brcmfmac looks for: the board-specific
# brcmfmac43456-sdio.<board_type>.txt, where board_type is the FIRST root
# `compatible` string of the live DT ("thundercomm,rubikpi3" -- comma kept,
# and note it is NOT hyphenated like the marketing name), and the generic
# brcmfmac43456-sdio.txt fallback. The fallback is load-bearing, not
# belt-and-braces: on the GRUB firmware-DT fallback path the root compatible
# is whatever EDK2 supplies, and without a generic NVRAM the WLAN half comes
# up with no calibration at all.
#
# BT (hci_bcm serdev child of &uart7, compatible "brcm,bcm4345c5"). The
# patchram is taken from the board vendor, NOT armbian: armbian's
# BCM4345C5.hcd identifies as "Ampak_CL1 UART 37.4 MHz BT 5.0
# [Version: 0039.0089]" while the vendor's is the module-specific
# "Ampak AP6256 UART 37.4 MHz BT 5.2 [Version: 1081.1154]".
#
# Both extra-download commits are pinned; on any bump re-check that the
# NVRAM still matches the vendor file and that the .hcd version string still
# names this module.
#
################################################################################

RUBIK_PI3_FIRMWARE_VERSION = 2113cae26e994948ffc871d29f6206631ee2fc81
RUBIK_PI3_FIRMWARE_SITE = $(call github,linux-msm,hexagon-dsp-binaries,$(RUBIK_PI3_FIRMWARE_VERSION))
RUBIK_PI3_FIRMWARE_LICENSE = Qualcomm firmware license, MIT, Broadcom bcm43xx firmware license
RUBIK_PI3_FIRMWARE_LICENSE_FILES = LICENSE.qcom LICENSE.qcom-2 LICENSE.MIT
RUBIK_PI3_FIRMWARE_REDISTRIBUTE = NO
RUBIK_PI3_FIRMWARE_DEPENDENCIES = linux-firmware

# Pinned vendor commits for the AP6256 blobs (see header).
RUBIK_PI3_FIRMWARE_ARMBIAN_FW_VERSION = d9846710f54da5e4383e2d67311819659ac2cf5c
RUBIK_PI3_FIRMWARE_ARMBIAN_FW_SITE = \
	https://raw.githubusercontent.com/armbian/firmware/$(RUBIK_PI3_FIRMWARE_ARMBIAN_FW_VERSION)/brcm
RUBIK_PI3_FIRMWARE_VENDOR_FW_VERSION = 040261c20ef198bae98eecaba4eb70c614f02984
RUBIK_PI3_FIRMWARE_VENDOR_FW_SITE = \
	https://raw.githubusercontent.com/rubikpi-ai/rubikpi3-firmware/$(RUBIK_PI3_FIRMWARE_VENDOR_FW_VERSION)/lib/firmware

RUBIK_PI3_FIRMWARE_EXTRA_DOWNLOADS = \
	$(RUBIK_PI3_FIRMWARE_ARMBIAN_FW_SITE)/brcmfmac43456-sdio.bin \
	$(RUBIK_PI3_FIRMWARE_ARMBIAN_FW_SITE)/brcmfmac43456-sdio.clm_blob \
	$(RUBIK_PI3_FIRMWARE_ARMBIAN_FW_SITE)/nvram_ap6256.txt \
	$(RUBIK_PI3_FIRMWARE_VENDOR_FW_SITE)/brcm/BCM4345C5.hcd

# The DSP shells/skels are Hexagon (QUALCOMM DSP6) ELF objects executed by
# the DSPs, not the AArch64 host -- exempt them from check-bin-arch (the
# /lib/firmware installs are exempt by default).
RUBIK_PI3_FIRMWARE_BIN_ARCH_EXCLUDE = /usr/lib/dsp

RUBIK_PI3_FIRMWARE_LF_DIR = $(BUILD_DIR)/linux-firmware-$(LINUX_FIRMWARE_VERSION)
RUBIK_PI3_FIRMWARE_FW_DIR = $(TARGET_DIR)/lib/firmware
RUBIK_PI3_FIRMWARE_RP3_DIR = $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcs6490/Thundercomm/RubikPi3
RUBIK_PI3_FIRMWARE_CDSP_LIBS = $(@D)/qcm6490/Thundercomm/RB3gen2/CDSP.HT.2.5.c3-00134-KODIAK-1
RUBIK_PI3_FIRMWARE_ADSP_LIBS = $(@D)/qcs6490/Thundercomm/RubikPi3/ADSP.HT.5.5.c8-00217-KODIAK-1

# board_type brcmfmac derives from the live DT's first root compatible.
RUBIK_PI3_FIRMWARE_BOARD_TYPE = thundercomm,rubikpi3

define RUBIK_PI3_FIRMWARE_INSTALL_TARGET_CMDS
	# Matched-pair guard: each .mbn and its shells MUST carry the same
	# QC_IMAGE_VERSION_STRING (the shell dir is named after it). A mismatch
	# only surfaces at runtime as fastrpc error 0x80000600 with no kernel
	# log -- fail the build loudly instead. (Hit twice during Q6A bring-up.)
	cdsp_ver=$$(strings $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcm6490/cdsp.mbn \
			| sed -n 's/^QC_IMAGE_VERSION_STRING=//p' | head -1); \
		shell_ver=$$(basename $(RUBIK_PI3_FIRMWARE_CDSP_LIBS)); \
		test -n "$$cdsp_ver" && test "$$cdsp_ver" = "$$shell_ver" || { \
			echo "rubik-pi3-firmware: CDSP matched-pair violation: cdsp.mbn='$$cdsp_ver' shells='$$shell_ver'"; \
			exit 1; \
		}
	adsp_ver=$$(strings $(RUBIK_PI3_FIRMWARE_RP3_DIR)/adsp.mbn \
			| sed -n 's/^QC_IMAGE_VERSION_STRING=//p' | head -1); \
		shell_ver=$$(basename $(RUBIK_PI3_FIRMWARE_ADSP_LIBS)); \
		test -n "$$adsp_ver" && test "$$adsp_ver" = "$$shell_ver" || { \
			echo "rubik-pi3-firmware: ADSP matched-pair violation: adsp.mbn='$$adsp_ver' shells='$$shell_ver'"; \
			exit 1; \
		}
	# Adreno 643 GPU (requested from qcom/ and qcom/qcs6490/)
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/a660_gmu.bin \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/a660_gmu.bin
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/a660_sqe.fw \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/a660_sqe.fw
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcm6490/a660_zap.mbn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/a660_zap.mbn
	# GENI QUP serial engines (DTS requests the qcm6490 path)
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcm6490/qupv3fw.elf \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcm6490/qupv3fw.elf
	# Venus video codec (sc7280 driver requests qcom/vpu-2.0/venus.mbn)
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/vpu/vpu20_p1.mbn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/vpu-2.0/venus.mbn
	# Board audio topology (QCS6490-Thundercomm-RubikPi3-tplg.bin) is NOT
	# installed: analog audio is not a bring-up gate, so the card probe is
	# deferred. The ax88179_178a NIC driver itself needs no blob, but its
	# upstream Renesas uPD720201 xHC (CONFIG_USB_XHCI_PCI_RENESAS=y, see
	# linux-7.1.defconfig) requires renesas_usb_fw.mem at probe, which is
	# NOT present anywhere in the pinned linux-firmware (LINUX_FIRMWARE_VERSION
	# 20260410) tree -- verified absent from WHENCE and from three
	# separately extracted build trees of this exact snapshot. USB3/ethernet will
	# still fail "-110"/ENOENT until that blob is sourced -- from a newer
	# linux-firmware snapshot or a pinned vendor mirror, matching the
	# AP6256 EXTRA_DOWNLOADS pattern above -- and installed here as
	# $(RUBIK_PI3_FIRMWARE_FW_DIR)/renesas_usb_fw.mem (bare name, no
	# subdir: that's what the driver requests).
	# ADSP: board image + fastrpc domain descriptors, at the DTS path
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_RP3_DIR)/adsp.mbn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/Thundercomm/RubikPi3/adsp.mbn
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_RP3_DIR)/adspr.jsn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/Thundercomm/RubikPi3/adspr.jsn
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_RP3_DIR)/adsps.jsn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/Thundercomm/RubikPi3/adsps.jsn
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_RP3_DIR)/adspua.jsn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/Thundercomm/RubikPi3/adspua.jsn
	# CDSP: the generic c3-00134 image, which is what the mainline DTS asks
	# for. Matched-pair rule for the contents, see header.
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcm6490/cdsp.mbn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/cdsp.mbn
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/qcom/qcm6490/cdspr.jsn \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/qcom/qcs6490/cdspr.jsn
	# DSP-side shells + skels. Separate per-domain dirs (the sysmon skel
	# names collide between ADSP and CDSP sets); the fastrpc package
	# patches its built-in search path to look in /usr/lib/dsp/cdsp
	# first, and per-process DSP_LIBRARY_PATH/ADSP_LIBRARY_PATH env can
	# override per domain.
	mkdir -p $(TARGET_DIR)/usr/lib/dsp/cdsp $(TARGET_DIR)/usr/lib/dsp/adsp
	$(INSTALL) -m 0644 $(RUBIK_PI3_FIRMWARE_CDSP_LIBS)/* \
		$(TARGET_DIR)/usr/lib/dsp/cdsp/
	$(INSTALL) -m 0644 $(RUBIK_PI3_FIRMWARE_ADSP_LIBS)/* \
		$(TARGET_DIR)/usr/lib/dsp/adsp/
	# Onboard AP6256: brcmfmac WiFi firmware + CLM regulatory blob
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_DL_DIR)/brcmfmac43456-sdio.bin \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/brcm/brcmfmac43456-sdio.bin
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_DL_DIR)/brcmfmac43456-sdio.clm_blob \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/brcm/brcmfmac43456-sdio.clm_blob
	# Board NVRAM under both names brcmfmac looks for (see header)
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_DL_DIR)/nvram_ap6256.txt \
		'$(RUBIK_PI3_FIRMWARE_FW_DIR)/brcm/brcmfmac43456-sdio.$(RUBIK_PI3_FIRMWARE_BOARD_TYPE).txt'
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_DL_DIR)/nvram_ap6256.txt \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/brcm/brcmfmac43456-sdio.txt
	# Onboard AP6256: hci_bcm patchram for the BT half
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_DL_DIR)/BCM4345C5.hcd \
		$(RUBIK_PI3_FIRMWARE_FW_DIR)/brcm/BCM4345C5.hcd
endef

# The Broadcom blobs are covered by a license file that lives in the
# LINUX-FIRMWARE tree, which <PKG>_LICENSE_FILES cannot reference (it only
# copies from this package's own source dir). Copy it into our legal-info
# output directly; the supported build flow ("source all legal-info")
# guarantees linux-firmware is extracted by legal-info time. (The blobs
# themselves come from the vendor repos above; this is Broadcom's own
# redistribution notice for exactly these bcm43xx files.)
define RUBIK_PI3_FIRMWARE_ADD_LINUX_FIRMWARE_LICENSES
	$(INSTALL) -D -m 0644 $(RUBIK_PI3_FIRMWARE_LF_DIR)/LICENCE.broadcom_bcm43xx \
		$(LEGAL_INFO_DIR)/licenses/$(RUBIK_PI3_FIRMWARE_BASENAME_RAW)/LICENCE.broadcom_bcm43xx
endef
RUBIK_PI3_FIRMWARE_POST_LEGAL_INFO_HOOKS += RUBIK_PI3_FIRMWARE_ADD_LINUX_FIRMWARE_LICENSES

$(eval $(generic-package))
