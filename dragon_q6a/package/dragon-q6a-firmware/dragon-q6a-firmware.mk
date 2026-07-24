################################################################################
#
# dragon-q6a-firmware
#
# Firmware for the Radxa Dragon Q6A (QCS6490) AI foundation. Two sources:
#
# 1. Upstream linux-firmware (the same tarball Buildroot's linux-firmware
#    package downloads -- this package DEPENDS on it and copies files
#    straight out of its extracted source tree instead of fetching a second
#    450 MB copy). File paths below are the REAL files; the qcom/qcs6490/*
#    names the kernel requests are WHENCE symlinks materialized only at
#    linux-firmware's own install step, so we install to the requested path
#    explicitly.
#
# 2. linux-msm/hexagon-dsp-binaries (this package's own download) for the
#    DSP-side shell/skel binaries that fastrpc loads into the CDSP/ADSP.
#
# MATCHED-PAIR RULE (do not break; failure mode is fastrpc error
# 0x80000600 with no kernel log): the cdsp.mbn the kernel loads and the
# fastrpc_shell_* binaries must carry the same QC_IMAGE_VERSION_STRING.
# Verified for this pinning (2026-07-24, `strings | grep QC_IMAGE`):
#
#   linux-firmware qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn
#       = CDSP.HT.2.5.c4-00004-KODIAK-1
#   hexagon-dsp-binaries qcs6490/radxa/dragon-q6a/CDSP.HT.2.5.c4-00004-KODIAK-1/
#       = same string (dir name is the version)
#   linux-firmware qcom/qcs6490/radxa/dragon-q6a/adsp.mbn
#       = ADSP.HT.5.5.c9-00028-KODIAK-2 (matches ADSP dir likewise)
#
# The GENERIC qcom/qcm6490/cdsp.mbn in linux-firmware is c3-00134 and does
# NOT match these shells -- which is why the board cdsp.mbn is installed at
# the generic path qcom/qcs6490/cdsp.mbn that the mainline DTS requests.
#
################################################################################

DRAGON_Q6A_FIRMWARE_VERSION = 2113cae26e994948ffc871d29f6206631ee2fc81
DRAGON_Q6A_FIRMWARE_SITE = $(call github,linux-msm,hexagon-dsp-binaries,$(DRAGON_Q6A_FIRMWARE_VERSION))
DRAGON_Q6A_FIRMWARE_LICENSE = Qualcomm firmware license, MIT
DRAGON_Q6A_FIRMWARE_LICENSE_FILES = LICENSE.qcom LICENSE.qcom-2 LICENSE.MIT
DRAGON_Q6A_FIRMWARE_REDISTRIBUTE = NO
DRAGON_Q6A_FIRMWARE_DEPENDENCIES = linux-firmware

# The DSP shells/skels are Hexagon (QUALCOMM DSP6) ELF objects executed by
# the DSPs, not the AArch64 host -- exempt them from check-bin-arch (the
# /lib/firmware installs are exempt by default).
DRAGON_Q6A_FIRMWARE_BIN_ARCH_EXCLUDE = /usr/lib/dsp

DRAGON_Q6A_FIRMWARE_LF_DIR = $(BUILD_DIR)/linux-firmware-$(LINUX_FIRMWARE_VERSION)
DRAGON_Q6A_FIRMWARE_FW_DIR = $(TARGET_DIR)/lib/firmware
DRAGON_Q6A_FIRMWARE_Q6A_DIR = $(@D)/qcs6490/radxa/dragon-q6a
DRAGON_Q6A_FIRMWARE_CDSP_LIBS = CDSP.HT.2.5.c4-00004-KODIAK-1
DRAGON_Q6A_FIRMWARE_ADSP_LIBS = ADSP.HT.5.5.c9-00028-KODIAK-2

define DRAGON_Q6A_FIRMWARE_INSTALL_TARGET_CMDS
	# Adreno 643 GPU (requested from qcom/ and qcom/qcs6490/)
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/a660_gmu.bin \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/a660_gmu.bin
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/a660_sqe.fw \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/a660_sqe.fw
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcm6490/a660_zap.mbn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/a660_zap.mbn
	# GENI QUP serial engines (DTS requests the qcm6490 path)
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcm6490/qupv3fw.elf \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcm6490/qupv3fw.elf
	# Venus video codec (sc7280 driver requests qcom/vpu-2.0/venus.mbn)
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/vpu/vpu20_p1.mbn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/vpu-2.0/venus.mbn
	# ADSP: board-matched image + fastrpc domain descriptors (DTS path)
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/radxa/dragon-q6a/adsp.mbn
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcs6490/radxa/dragon-q6a/adspr.jsn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/radxa/dragon-q6a/adspr.jsn
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcs6490/radxa/dragon-q6a/adspua.jsn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/radxa/dragon-q6a/adspua.jsn
	# CDSP: board cdsp.mbn (c4-00004) installed AT the generic path the
	# mainline DTS requests -- matched-pair rule, see header.
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcs6490/radxa/dragon-q6a/cdsp.mbn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/cdsp.mbn
	$(INSTALL) -D -m 0644 $(DRAGON_Q6A_FIRMWARE_LF_DIR)/qcom/qcs6490/radxa/dragon-q6a/cdspr.jsn \
		$(DRAGON_Q6A_FIRMWARE_FW_DIR)/qcom/qcs6490/cdspr.jsn
	# DSP-side shells + skels. Separate per-domain dirs (the sysmon skel
	# names collide between ADSP and CDSP sets); daemons/tests point at
	# them via DSP_LIBRARY_PATH / ADSP_LIBRARY_PATH (fastrpc default
	# search path already includes /usr/lib/dsp).
	mkdir -p $(TARGET_DIR)/usr/lib/dsp/cdsp $(TARGET_DIR)/usr/lib/dsp/adsp
	$(INSTALL) -m 0644 $(DRAGON_Q6A_FIRMWARE_Q6A_DIR)/$(DRAGON_Q6A_FIRMWARE_CDSP_LIBS)/* \
		$(TARGET_DIR)/usr/lib/dsp/cdsp/
	$(INSTALL) -m 0644 $(DRAGON_Q6A_FIRMWARE_Q6A_DIR)/$(DRAGON_Q6A_FIRMWARE_ADSP_LIBS)/* \
		$(TARGET_DIR)/usr/lib/dsp/adsp/
endef

$(eval $(generic-package))
