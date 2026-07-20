################################################################################
#
# vagus-balena-engine
#
# Vagus-owned fork of Buildroot's package/balena-engine, rebased on
# balenaOS's actually-shipped balena-engine revision (balena-os/meta-balena's
# `balena_git.bb` recipe pins `release/v25.0` @ this SRCREV, human version
# "v25.0.14") instead of the 20.10.26 tag Buildroot's own package still
# tracks, and with the "seccomp" build tag turned on (upstream's own
# Dockerfile default; both Buildroot's and balenaOS's own packagings
# otherwise omit it).
#
################################################################################

# Human-readable version / provenance (NOT used as the fetched VERSION --
# see VAGUS_BALENA_ENGINE_VERSION below, which pins the exact commit).
# balena-os/balena-engine branch: release/v25.0
# balena-os/balena-engine tag-equivalent (meta-balena BALENA_VERSION): v25.0.14
# Commit date: 2026-06-19T17:44:27Z
VAGUS_BALENA_ENGINE_DOCKER_VERSION = v25.0.14
VAGUS_BALENA_ENGINE_GITCOMMIT = d7af640

# VERSION is the git commit SRCREV meta-balena's own recipe pins on
# release/v25.0, so this package tracks exactly what balenaOS ships rather
# than an independently-chosen ref. Site fetches the GitHub commit tarball
# (not a `vNN.NN.NN` tag -- balena-os/balena-engine's release branches are
# not necessarily tagged at every commit meta-balena consumes).
VAGUS_BALENA_ENGINE_VERSION = d7af640472d60e72bf086cfdc5a3e35a35a0cf2e
VAGUS_BALENA_ENGINE_SITE = $(call github,balena-os,balena-engine,$(VAGUS_BALENA_ENGINE_VERSION))

VAGUS_BALENA_ENGINE_LICENSE = Apache-2.0
VAGUS_BALENA_ENGINE_LICENSE_FILES = LICENSE

VAGUS_BALENA_ENGINE_GOMOD = github.com/docker/docker

# LDFLAGS target the same two version-var packages as upstream Buildroot's
# stock balena-engine package (confirmed unmoved at this SRCREV by directly
# inspecting hack/make/.go-autogen, hack/make.sh, dockerversion/version_lib.go
# and vendor/github.com/docker/cli/cli/version/version.go in the pinned
# tree): the engine's own dockerversion.* vars and the vendored CLI
# subtree's version.* vars (cmd/balena-engine is a multicall binary that
# embeds the docker/balena CLI too). Unlike the stock 20.10.26 package
# (which stamps empty/N/A placeholders), Version/GitCommit are stamped with
# real values here, matching what hack/make/.go-autogen actually computes
# from $VERSION/$GITCOMMIT at a real build. containerd/runc stay "N/A" --
# they are vendored subcomponents with no independent Buildroot-tracked
# version of their own, same as the stock package.
VAGUS_BALENA_ENGINE_LDFLAGS = \
	-X $(VAGUS_BALENA_ENGINE_GOMOD)/dockerversion.GitCommit=$(VAGUS_BALENA_ENGINE_GITCOMMIT) \
	-X $(VAGUS_BALENA_ENGINE_GOMOD)/dockerversion.Version=$(VAGUS_BALENA_ENGINE_DOCKER_VERSION) \
	-X github.com/containerd/containerd/version.Version=N/A \
	-X github.com/docker/cli/cli/version.BuildTime= \
	-X github.com/docker/cli/cli/version.GitCommit=$(VAGUS_BALENA_ENGINE_GITCOMMIT) \
	-X github.com/docker/cli/cli/version.Version=$(VAGUS_BALENA_ENGINE_DOCKER_VERSION) \
	-X github.com/opencontainers/runc.version=N/A

# Same tag set as the stock 20.10.26-era BALENA_ENGINE_TAGS, plus "seccomp"
# (the one build-tag change this fork exists to make). Upstream's own
# Makefile default (DOCKER_BUILDTAGS, pinned-SRCREV Makefile) is
# "apparmor seccomp no_btrfs no_cri no_devmapper no_nri no_zfs
# exclude_disk_quota exclude_graphdriver_btrfs exclude_graphdriver_devicemapper
# exclude_graphdriver_zfs" -- this fork deliberately only picks up "seccomp"
# from that list (task scope), not "apparmor"/"no_nri"/"no_buildkit"; see
# report.md for the open note on those.
VAGUS_BALENA_ENGINE_TAGS = \
	cgo \
	seccomp \
	no_btrfs \
	no_cri \
	no_devmapper \
	no_zfs \
	exclude_disk_quota \
	exclude_graphdriver_btrfs \
	exclude_graphdriver_devicemapper \
	exclude_graphdriver_zfs

VAGUS_BALENA_ENGINE_BUILD_TARGETS = cmd/balena-engine

# seccomp is a cgo dependency here, not a pure-Go binding: the upstream
# Dockerfile's `build` stage apt-installs libseccomp-dev for the target
# arch (via xx-apt-get) specifically to compile cmd/balena-engine when the
# "seccomp" tag is set. So the staged libseccomp headers/.pc/.so need to be
# available to cgo at build time -- confirmed the same requirement
# docker-engine's existing Buildroot package already has (its Config.in
# selects BR2_PACKAGE_LIBSECCOMP unconditionally too).
VAGUS_BALENA_ENGINE_DEPENDENCIES = libseccomp

# ------------------------------------------------------------------------
# FIX_VENDORING -- rewritten for the v25 tree's vendoring layout
# ------------------------------------------------------------------------
#
# The stock (20.10.26-era) BALENA_ENGINE_FIX_VENDORING hook worked around a
# tree that had NO go.mod and an inconsistent/stale vendor/modules.txt: it
# stubbed a go.mod declaring "go 1.19" (deliberately below the Go version
# where `-mod=vendor` builds start requiring vendor/modules.txt to exist and
# match go.mod -- see
# https://github.com/moby/moby/issues/44618#issuecomment-1343565705) and then
# deleted vendor/modules.txt and vendor/archive outright, so there was
# nothing left for Go's vendor-consistency checker to reject.
#
# None of that applies to the pinned v25 rev (d7af640...), and reusing the
# trick verbatim would be actively wrong here:
#
#   - The tree already has a real, modern module manifest: `vendor.mod` /
#     `vendor.sum` at the repo root (module github.com/docker/docker,
#     go 1.23.9), with NO root go.mod/go.sum by design -- see the tree's own
#     VENDORING.md / vendor.mod header comment ("There is no 'go.mod' file,
#     as that would imply opting in for all the rules around SemVer, which
#     this repo cannot abide by as it uses CalVer."). Upstream's own build
#     path (hack/make/.binary) builds with
#     `go build -mod=vendor -modfile=vendor.mod ...`, i.e. it points Go at
#     vendor.mod directly instead of a go.mod.
#   - `vendor/modules.txt` is fully present, populated, and consistent with
#     vendor.mod (confirmed non-empty in the fetched tarball) -- deleting it
#     the way the old hook did would throw away real, correct information
#     and risk Go falling back to module-cache/network resolution for
#     anything it decides is inconsistent, which is impossible anyway under
#     Buildroot's forced `GOFLAGS=-mod=vendor GOPROXY=off`
#     (package/go/go.mk's HOST_GO_COMMON_ENV) -- it would fail outright
#     rather than silently degrade.
#   - `vendor/archive` does not exist at this rev at all (confirmed absent in
#     the fetched tarball), so that half of the old hook is now simply
#     obsolete cruft, not a fix.
#
# Buildroot's golang-package infra (pkg-golang.mk) has no concept of
# `-modfile=vendor.mod` -- it always does a plain `go build` against
# whatever go.mod exists at $(@D)/go.mod (its own generic <PKG>_GEN_GOMOD
# POST_PATCH hook only writes a *stub* `module ...` go.mod, with no `go`
# directive at all, and only if one doesn't already exist -- so it composes
# as a no-op here exactly like it did for the stock package, since this
# POST_EXTRACT hook runs first and always leaves a real go.mod behind).
#
# The fix: since `go mod vendor -modfile=vendor.mod` is exactly what
# generated the committed vendor/ tree from vendor.mod in the first place,
# copying vendor.mod -> go.mod (and vendor.sum -> go.sum) reproduces the
# real manifest vendor/modules.txt was built against, byte for byte. Go's
# `-mod=vendor` build then sees a self-consistent go.mod/go.sum/vendor/
# triple with no network access required -- vendor/modules.txt is left
# completely untouched.
#
# NOT hands-on build-verified (flagged as Gate A's #1 open risk in the
# vagus-runtime-spike plan, task 1.5): whether go 1.23.9's stricter
# `-mod=vendor` consistency checking accepts a go.mod that is a renamed
# vendor.mod copy the same way it accepted the old go-1.19 stub for the
# 20.10.26 tree. This is the first thing to check if the build fails with a
# "vendor/modules.txt is out of sync" or similar error.
#
# Idempotent: both cp -f invocations simply overwrite the destination each
# time, so re-running this hook (e.g. after a `-reconfigure`/partial rebuild
# that re-triggers POST_EXTRACT) is always safe and produces the same
# result.
define VAGUS_BALENA_ENGINE_FIX_VENDORING
	cp -f $(@D)/vendor.mod $(@D)/go.mod
	cp -f $(@D)/vendor.sum $(@D)/go.sum
endef
VAGUS_BALENA_ENGINE_POST_EXTRACT_HOOKS += VAGUS_BALENA_ENGINE_FIX_VENDORING

ifeq ($(BR2_INIT_SYSTEMD),y)
VAGUS_BALENA_ENGINE_DEPENDENCIES += systemd
VAGUS_BALENA_ENGINE_TAGS += journald
endif

define VAGUS_BALENA_ENGINE_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 644 $(@D)/contrib/init/systemd/balena-engine.service \
		$(TARGET_DIR)/usr/lib/systemd/system/balena-engine.service
	$(INSTALL) -D -m 644 $(@D)/contrib/init/systemd/balena-engine.socket \
		$(TARGET_DIR)/usr/lib/systemd/system/balena-engine.socket
endef

define VAGUS_BALENA_ENGINE_USERS
	- - balena-engine -1 * - - - balenaEngine daemon
endef

define VAGUS_BALENA_ENGINE_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_POSIX_MQUEUE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_CGROUPS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NAMESPACES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_UTS_NS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IPC_NS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_PID_NS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NET_NS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NETFILTER)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NF_CONNTRACK)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NETFILTER_XT_MATCH_ADDRTYPE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_NETFILTER_XT_MATCH_CONNTRACK)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IP_NF_IPTABLES)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IP_NF_FILTER)
	$(call KCONFIG_ENABLE_OPT,CONFIG_IP_NF_NAT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_BRIDGE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_VETH)
endef

# Kept exactly as the stock 20.10.26-era package installs its argv0
# symlinks -- see report.md for why this fork does NOT (yet) switch to the
# different symlink set (adds "balenad", "balena-containerd-shim-runc-v2";
# drops "balena-engine-containerd-shim") that hack/make/.binary-symlinks
# actually produces at this v25 SRCREV.
define VAGUS_BALENA_ENGINE_INSTALL_SYMLINK
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-daemon
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-containerd
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-containerd-shim
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-containerd-ctr
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-runc
	ln -f -s balena-engine $(TARGET_DIR)/usr/bin/balena-engine-proxy
	$(if $(BR2_PACKAGE_TINI),ln -f -s tini $(TARGET_DIR)/usr/bin/balena-engine-init)
endef
VAGUS_BALENA_ENGINE_POST_INSTALL_TARGET_HOOKS += VAGUS_BALENA_ENGINE_INSTALL_SYMLINK

$(eval $(golang-package))
