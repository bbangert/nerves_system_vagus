# Monorepo helpers for the custom Nerves systems.
#
# Shared kernel config fragments live in shared/*.config. Each target subdir
# must be SELF-CONTAINED (its own copy), so the main project can pull a single
# target via a git `sparse:` dep and artifact checksums cover every build
# input. `make sync` materializes the shared fragment(s) into each target;
# edit shared/, run `make sync`, commit. shared/ also carries rootfs overlay
# files (currently sysctl.conf), synced the same way into each target's
# rootfs_overlay/etc/. shared/package/<name>/ holds Buildroot packages, synced
# as whole directories into <target>/package/<name>/ for PKG_TARGETS.
#
# The Qualcomm boards (BASE_TARGETS) are a product layer over a vendored board
# system: <target>/base/ is a `git subtree --squash` of BASE_REPO_<target>,
# never edited here (`make base-pull` moves it). scripts/sync-base.sh
# generates the target's nerves_defconfig, Config.in and erlinit.config from
# base/ plus the target's *.fragment files; `make sync` runs it.
#
# Controller firmware is NOT vendored here — each system enables
# BR2_PACKAGE_RPI_DISTRO_BLUEZ_FIRMWARE, which installs the Pi BT .hcd set
# (and the board-specific symlinks btbcm wants) at build time.

# Every target fork. rpi/rpi2 (no onboard BT) and x86_64 are included for USB
# Bluetooth adapters + USB audio; the onboard-BT kernel symbols in the shared
# fragment are inert there but harmless.
TARGETS := dragon_q6a rpi rpi0 rpi0_2 rpi2 rpi3 rpi3_64 rpi4 rpi5 rubik_pi3 x86_64

# Only the boards that ship a container engine carry its Buildroot package.
PKG_TARGETS := dragon_q6a rpi3_64 rubik_pi3

BASE_TARGETS := dragon_q6a rubik_pi3
BASE_REPO_dragon_q6a := https://github.com/bbangert/nerves_system_q6a.git
BASE_REPO_rubik_pi3 := https://github.com/bbangert/nerves_system_rubik.git

PKGS := $(wildcard shared/package/*)
CFG := $(wildcard shared/*.config)
OVERLAY_FILES := $(wildcard shared/sysctl.conf)

.PHONY: sync check base-pull check-base-pristine

## Copy shared kernel fragment(s) and overlay file(s) into every target subdir,
## then regenerate the layered files of the base targets.
sync:
	@for t in $(TARGETS); do \
	  for f in $(CFG); do \
	    install -m 0644 "$$f" "$$t/$$(basename $$f)"; \
	    echo "synced $$f -> $$t/"; \
	  done; \
	  for f in $(OVERLAY_FILES); do \
	    install -D -m 0644 "$$f" "$$t/rootfs_overlay/etc/$$(basename $$f)"; \
	    echo "synced $$f -> $$t/rootfs_overlay/etc/"; \
	  done; \
	done; \
	for t in $(PKG_TARGETS); do \
	  for p in $(PKGS); do \
	    rm -rf "$$t/package/$$(basename $$p)"; \
	    mkdir -p "$$t/package"; \
	    cp -a "$$p" "$$t/package/$$(basename $$p)"; \
	    echo "synced $$p -> $$t/package/"; \
	  done; \
	done
	@for t in $(BASE_TARGETS); do scripts/sync-base.sh $$t || exit 1; done

## Fail if any target's copy has drifted from shared/ (use in CI).
check:
	@status=0; \
	for t in $(TARGETS); do \
	  for f in $(CFG); do \
	    cmp -s "$$f" "$$t/$$(basename $$f)" || { echo "DRIFT: $$t/$$(basename $$f) (run 'make sync')"; status=1; }; \
	  done; \
	  for f in $(OVERLAY_FILES); do \
	    cmp -s "$$f" "$$t/rootfs_overlay/etc/$$(basename $$f)" || { echo "DRIFT: $$t/rootfs_overlay/etc/$$(basename $$f) (run 'make sync')"; status=1; }; \
	  done; \
	done; \
	for t in $(PKG_TARGETS); do \
	  for p in $(PKGS); do \
	    diff -r "$$p" "$$t/package/$$(basename $$p)" >/dev/null 2>&1 || { echo "DRIFT: $$t/package/$$(basename $$p) (run 'make sync')"; status=1; }; \
	  done; \
	done; \
	for t in $(BASE_TARGETS); do \
	  scripts/sync-base.sh $$t --check || status=1; \
	done; \
	out=$$(scripts/sync-base-test.sh 2>&1) || { echo "$$out"; status=1; }; \
	[ $$status -eq 0 ] && echo "ok: all targets in sync"; \
	exit $$status

## Move a base target's vendored board system to another tag, then regenerate.
base-pull:
	@test -n "$(BASE)" && test -n "$(REF)" || { echo "usage: make base-pull BASE=<target> REF=<tag>"; exit 2; }
	@test -n "$(BASE_REPO_$(BASE))" || { echo "$(BASE) is not one of: $(BASE_TARGETS)"; exit 2; }
	git subtree pull --prefix=$(BASE)/base $(BASE_REPO_$(BASE)) $(REF) --squash -m "Pull $(BASE) base $(REF)"
	$(MAKE) sync

## Fail if any <target>/base/ differs from the base repo's tag named by its
## VERSION, i.e. someone edited the vendored copy. Needs network (CI).
check-base-pristine:
	@set -e; $(foreach t,$(BASE_TARGETS), \
	  tag=v$$(cat $(t)/base/VERSION); \
	  git fetch --quiet --no-tags $(BASE_REPO_$(t)) "refs/tags/$$tag"; \
	  git diff --quiet FETCH_HEAD "HEAD:$(t)/base" || { echo "DRIFT: $(t)/base differs from $(BASE_REPO_$(t)) $$tag"; exit 1; }; \
	  echo "ok: $(t)/base matches $$tag";)
