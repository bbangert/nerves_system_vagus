################################################################################
#
# vagus-podman
#
################################################################################

VAGUS_PODMAN_VERSION = v6.1.4
VAGUS_PODMAN_SITE = $(call github,podman-container-tools,podman,$(VAGUS_PODMAN_VERSION))
VAGUS_PODMAN_LICENSE = Apache-2.0
VAGUS_PODMAN_LICENSE_FILES = LICENSE

VAGUS_PODMAN_GOMOD = go.podman.io/podman/v6
VAGUS_PODMAN_BUILD_TARGETS = cmd/podman
VAGUS_PODMAN_DEPENDENCIES = host-pkgconf libseccomp

# exclude_graphdriver_btrfs and containers_image_openpgp are what keep
# the btrfs headers and gpgme out of the build. Leaving out systemd,
# apparmor and libsubid selects the cgroupfs/file/k8s-file defaults and
# drops rootless id mapping.
VAGUS_PODMAN_TAGS = \
	grpcnotrace \
	seccomp \
	exclude_graphdriver_btrfs \
	containers_image_openpgp

# No libsqlite3 tag: podman's state database always uses the sqlite
# amalgamation vendored with go-sqlite3, compiled in through cgo, so the
# build does not change when some other package selects BR2_PACKAGE_SQLITE.

# The archive has no git metadata, and a build-time stamp would make
# the binary unreproducible: stamp the tag's commit and commit time.
VAGUS_PODMAN_GIT_COMMIT = 464c15fec06f0074c916f9eff87c4806869c2833
VAGUS_PODMAN_GIT_COMMIT_TIME = 1791824867
VAGUS_PODMAN_LDFLAGS = \
	-X $(VAGUS_PODMAN_GOMOD)/libpod/define.gitCommit=$(VAGUS_PODMAN_GIT_COMMIT) \
	-X $(VAGUS_PODMAN_GOMOD)/libpod/define.buildInfo=$(VAGUS_PODMAN_GIT_COMMIT_TIME) \
	-X $(VAGUS_PODMAN_GOMOD)/libpod/define.buildOrigin=vagus

# --init runs init_path, whose default is this link. vagus-netavark adds
# its own link here; there is none for aardvark-dns, so container DNS is off.
define VAGUS_PODMAN_INSTALL_HELPERS
	mkdir -p $(TARGET_DIR)/usr/libexec/podman
	ln -sf ../../bin/catatonit $(TARGET_DIR)/usr/libexec/podman/catatonit
endef
VAGUS_PODMAN_POST_INSTALL_TARGET_HOOKS += VAGUS_PODMAN_INSTALL_HELPERS

define VAGUS_PODMAN_INSTALL_CONFIG
	$(INSTALL) -D -m 0644 $(VAGUS_PODMAN_PKGDIR)/containers.conf \
		$(TARGET_DIR)/etc/containers/containers.conf
	$(INSTALL) -D -m 0644 $(VAGUS_PODMAN_PKGDIR)/storage.conf \
		$(TARGET_DIR)/etc/containers/storage.conf
endef
VAGUS_PODMAN_POST_INSTALL_TARGET_HOOKS += VAGUS_PODMAN_INSTALL_CONFIG

$(eval $(golang-package))
