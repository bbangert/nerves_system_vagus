################################################################################
#
# vagus-netavark
#
################################################################################

VAGUS_NETAVARK_VERSION = 2.1.0
VAGUS_NETAVARK_SITE = $(call github,containers,netavark,v$(VAGUS_NETAVARK_VERSION))
VAGUS_NETAVARK_LICENSE = Apache-2.0
VAGUS_NETAVARK_LICENSE_FILES = LICENSE

# build.rs compiles src/proto/proxy.proto with protoc.
VAGUS_NETAVARK_DEPENDENCIES = host-protobuf
VAGUS_NETAVARK_CARGO_ENV = PROTOC=$(HOST_DIR)/bin/protoc

# The other two [[bin]] targets are upstream test tools.
VAGUS_NETAVARK_CARGO_BUILD_OPTS = --bin netavark

# Not the infra's `cargo install --bins`: --bins overrides any --bin, so the
# test tools would be installed, and it always uses the release profile, which
# is a second full compile under BR2_ENABLE_DEBUG.
# podman resolves netavark through helper_binaries_dir only, never PATH.
define VAGUS_NETAVARK_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 \
		$(@D)/target/$(RUSTC_TARGET_NAME)/$(if $(BR2_ENABLE_DEBUG),debug,release)/netavark \
		$(TARGET_DIR)/usr/bin/netavark
	mkdir -p $(TARGET_DIR)/usr/libexec/podman
	ln -sf ../../bin/netavark $(TARGET_DIR)/usr/libexec/podman/netavark
endef

# No _LINUX_CONFIG_FIXUPS: linux-containers.config owns the nf_tables
# symbols, and Buildroot's netavark list enables many that 2.x never uses.

$(eval $(cargo-package))
