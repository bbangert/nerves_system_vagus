# Monorepo helpers for the custom Nerves systems.
#
# Shared kernel config fragments live in shared/*.config. Each target subdir
# must be SELF-CONTAINED (its own copy), so the main project can pull a single
# target via a git `sparse:` dep and artifact checksums cover every build
# input. `make sync` materializes the shared fragment(s) into each target;
# edit shared/, run `make sync`, commit.
#
# Controller firmware is NOT vendored here — each system enables
# BR2_PACKAGE_RPI_DISTRO_BLUEZ_FIRMWARE, which installs the Pi BT .hcd set
# (and the board-specific symlinks btbcm wants) at build time.

# Every target fork. rpi/rpi2 (no onboard BT) and x86_64 are included for USB
# Bluetooth adapters + USB audio; the onboard-BT kernel symbols in the shared
# fragment are inert there but harmless.
TARGETS := dragon_q6a rpi rpi0 rpi0_2 rpi2 rpi3 rpi3_64 rpi4 rpi5 rubik_pi3 x86_64

CFG := $(wildcard shared/*.config)

.PHONY: sync check

## Copy shared kernel fragment(s) into every target subdir.
sync:
	@for t in $(TARGETS); do \
	  for f in $(CFG); do \
	    install -m 0644 "$$f" "$$t/$$(basename $$f)"; \
	    echo "synced $$f -> $$t/"; \
	  done; \
	done

## Fail if any target's copy has drifted from shared/ (use in CI).
check:
	@status=0; \
	for t in $(TARGETS); do \
	  for f in $(CFG); do \
	    cmp -s "$$f" "$$t/$$(basename $$f)" || { echo "DRIFT: $$t/$$(basename $$f) (run 'make sync')"; status=1; }; \
	  done; \
	done; \
	[ $$status -eq 0 ] && echo "ok: all targets in sync"; \
	exit $$status
