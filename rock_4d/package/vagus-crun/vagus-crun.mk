################################################################################
#
# vagus-crun
#
################################################################################

VAGUS_CRUN_VERSION = 1.30.1
VAGUS_CRUN_SOURCE = crun-$(VAGUS_CRUN_VERSION).tar.gz
VAGUS_CRUN_SITE = https://github.com/containers/crun/releases/download/$(VAGUS_CRUN_VERSION)
VAGUS_CRUN_DEPENDENCIES = host-pkgconf json-c libcap libseccomp

VAGUS_CRUN_LICENSE = GPL-2.0+ (crun binary), LGPL-2.1+ (libcrun)
VAGUS_CRUN_LICENSE_FILES = COPYING COPYING.libcrun

# The tarball's libtool files are Debian-patched 2.4.7, not a shape
# Buildroot's libtool cross-compile patch is written for.
VAGUS_CRUN_AUTORECONF = YES

# HAVE_EBPF gates the cgroup-v2 device filter (src/libcrun/ebpf.c); without
# it crun installs no filter and silently leaves devices unrestricted.
# configure only needs linux/bpf.h to compile (no libbpf), so it is on by
# default; --enable-bpf just makes that explicit.
# Without HAVE_CAP crun zeroes every capability set it parses
# (read_caps() in src/libcrun/linux.c), so libcap is mandatory.
# Forced embedded blake3 keeps host pkg-config from picking up a libblake3.
VAGUS_CRUN_CONF_OPTS = \
	--enable-bpf \
	--enable-caps \
	--enable-seccomp \
	--enable-embedded-blake3 \
	--disable-systemd \
	--disable-criu

ifeq ($(BR2_TOOLCHAIN_HAS_LIBATOMIC),y)
VAGUS_CRUN_CONF_ENV += LIBS=-latomic
endif

ifeq ($(BR2_PACKAGE_ARGP_STANDALONE),y)
VAGUS_CRUN_DEPENDENCIES += argp-standalone
endif

# No /usr/bin/runc -> crun symlink (the stock package adds one): podman
# runs crun by the path containers.conf gives it.

$(eval $(autotools-package))
