# Cross-compiles the on-device smoke tests with the Nerves toolchain.
# Not part of the system image -- built on demand and copied to /data.
#
#   make CROSS_COMPILE=~/.nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-linux_x86_64-15.3.0/bin/aarch64-nerves-linux-gnu-

CROSS_COMPILE ?= aarch64-nerves-linux-gnu-
CC = $(CROSS_COMPILE)gcc
CFLAGS ?= -O2 -Wall -Wextra
# -static lives in LDFLAGS (unconditional) so an exported CFLAGS cannot
# silently produce a dynamically-linked binary.
LDFLAGS += -static

all: venus_dec_smoke

venus_dec_smoke: venus_dec_smoke.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f venus_dec_smoke

.PHONY: all clean
