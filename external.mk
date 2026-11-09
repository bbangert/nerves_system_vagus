# Self-locating so this file works both standalone and vendored under <product>/base/.
NERVES_BASE_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
include $(sort $(wildcard $(NERVES_BASE_DIR)/package/*/*.mk))
