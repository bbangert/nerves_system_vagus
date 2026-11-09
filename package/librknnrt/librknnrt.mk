################################################################################
#
# librknnrt — Rockchip RKNN NPU runtime (proprietary blob + C headers)
#
################################################################################

LIBRKNNRT_VERSION = 2.3.2
LIBRKNNRT_BASE = https://github.com/airockchip/rknn-toolkit2/raw/v$(LIBRKNNRT_VERSION)/rknpu2/runtime/Linux/librknn_api
LIBRKNNRT_SITE = $(LIBRKNNRT_BASE)/aarch64
LIBRKNNRT_SOURCE = librknnrt.so
LIBRKNNRT_EXTRA_DOWNLOADS = \
	$(LIBRKNNRT_BASE)/include/rknn_api.h \
	$(LIBRKNNRT_BASE)/include/rknn_matmul_api.h \
	$(LIBRKNNRT_BASE)/include/rknn_custom_op.h
LIBRKNNRT_LICENSE = PROPRIETARY (Rockchip)
LIBRKNNRT_INSTALL_STAGING = YES

define LIBRKNNRT_EXTRACT_CMDS
	cp $(LIBRKNNRT_DL_DIR)/librknnrt.so $(@D)/
	cp $(LIBRKNNRT_DL_DIR)/rknn_api.h $(LIBRKNNRT_DL_DIR)/rknn_matmul_api.h \
		$(LIBRKNNRT_DL_DIR)/rknn_custom_op.h $(@D)/
endef

define LIBRKNNRT_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/librknnrt.so $(STAGING_DIR)/usr/lib/librknnrt.so
	$(INSTALL) -D -m 0644 $(@D)/rknn_api.h $(STAGING_DIR)/usr/include/rknn_api.h
	$(INSTALL) -D -m 0644 $(@D)/rknn_matmul_api.h $(STAGING_DIR)/usr/include/rknn_matmul_api.h
	$(INSTALL) -D -m 0644 $(@D)/rknn_custom_op.h $(STAGING_DIR)/usr/include/rknn_custom_op.h
endef

define LIBRKNNRT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/librknnrt.so $(TARGET_DIR)/usr/lib/librknnrt.so
endef

$(eval $(generic-package))
