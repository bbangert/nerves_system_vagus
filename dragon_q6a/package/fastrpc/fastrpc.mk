################################################################################
#
# fastrpc
#
# Qualcomm FastRPC userspace (BSD-3-Clause), pinned to v1.0.4 -- the same
# version RadxaOS ships and the one the q6a_ai bring-up validated 3/3 on
# `fastrpc_test -a v68` against the CDSP.HT.2.5.c4 firmware set installed
# by package/dragon-q6a-firmware.
#
# The tarball has no pre-generated ./configure (autogen.sh), so autoreconf.
# DEFAULT_DSP_SEARCH_PATHS is ";/usr/lib/rfsa/adsp;/usr/lib/dsp;"; the
# board shells live in /usr/lib/dsp/{adsp,cdsp} (per-domain dirs because
# the sysmon skel filenames collide), selected via ADSP_LIBRARY_PATH /
# DSP_LIBRARY_PATH when starting the daemons -- see the system README.
# The systemd units it installs are inert under Nerves (BR2_INIT_NONE);
# daemon supervision is app-level (MuonTrap).
#
################################################################################

FASTRPC_VERSION = 1.0.4
FASTRPC_SITE = $(call github,qualcomm,fastrpc,v$(FASTRPC_VERSION))
FASTRPC_LICENSE = BSD-3-Clause
FASTRPC_LICENSE_FILES = LICENSE.txt
FASTRPC_AUTORECONF = YES
FASTRPC_DEPENDENCIES = host-pkgconf libyaml libmd libbsd
FASTRPC_INSTALL_STAGING = YES

$(eval $(autotools-package))
