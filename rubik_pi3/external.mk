# nerves_system_br includes only this file, so base/ packages come in here.
include $(NERVES_DEFCONFIG_DIR)/base/external.mk
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))
