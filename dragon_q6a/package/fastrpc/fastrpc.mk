################################################################################
#
# fastrpc
#
# Qualcomm FastRPC userspace (BSD-3-Clause), pinned to v1.0.8, which
# carries the v1.0.5-v1.0.8 fixes: among them a use-after-free in session
# teardown (#365), missing unlocks on failure paths (#337) and input
# validation in the remote API entry points (#359).
# Whether `fastrpc_test -a v68` is device-validated on this pin, against
# the CDSP.HT.2.5.c3-00134 firmware set installed by
# package/dragon-q6a-firmware, is recorded in README.md's VERSIONS table,
# not here.
#
# The tarball has no pre-generated ./configure (autogen.sh), so autoreconf.
#
# DEFAULT_DSP_SEARCH_PATHS is patched (POST_PATCH hook below) to also
# search the per-domain dirs /usr/lib/dsp/{cdsp,adsp} where
# dragon-q6a-firmware installs the shells/skels. The stock compiled-in
# list (";/usr/lib/rfsa/adsp;/usr/lib/dsp;") is what open_shell() actually
# uses -- the DSP_LIBRARY_PATH env var does NOT affect the shell lookup
# (device-proven: fastrpc_test failed 0x27/ENOSUCH until the shell was
# reachable from the compiled-in list). Distro fastrpc packages
# (RadxaOS/Debian) work "out of the box" for the same reason. Per-process
# ADSP_LIBRARY_PATH/DSP_LIBRARY_PATH env still steer the DSP-side file
# opens (skels) -- note cdsp/ is searched before adsp/, so ADSP-domain
# processes should set ADSP_LIBRARY_PATH to avoid picking up CDSP sysmon
# skels of the same name.
#
# The systemd units, sysusers.d entry and udev rules it installs are inert
# under Nerves (BR2_INIT_NONE, no udev); daemon supervision is app-level
# (MuonTrap). Where udev rules are evaluated, upstream's 60-fastrpc.rules
# (root:fastrpc 0640 on the non-secure nodes) sorts before rootfs_overlay's
# 99-qcom-ai.rules, so the overlay's MODE="0666" is the one that applies.
#
################################################################################

FASTRPC_VERSION = 1.0.8
FASTRPC_SITE = $(call github,qualcomm,fastrpc,v$(FASTRPC_VERSION))
FASTRPC_LICENSE = BSD-3-Clause
FASTRPC_LICENSE_FILES = LICENSE.txt
FASTRPC_AUTORECONF = YES
FASTRPC_DEPENDENCIES = host-pkgconf libyaml libmd libbsd
FASTRPC_INSTALL_STAGING = YES

define FASTRPC_PATCH_DSP_SEARCH_PATHS
	$(SED) 's|DEFAULT_DSP_SEARCH_PATHS='\''";/usr/lib/rfsa/adsp;/usr/lib/dsp;"'\''|DEFAULT_DSP_SEARCH_PATHS='\''";/usr/lib/dsp/cdsp;/usr/lib/dsp/adsp;/usr/lib/rfsa/adsp;/usr/lib/dsp;"'\''|' \
		$(@D)/src/Makefile.am
	grep -q '/usr/lib/dsp/cdsp' $(@D)/src/Makefile.am
endef
FASTRPC_POST_PATCH_HOOKS += FASTRPC_PATCH_DSP_SEARCH_PATHS

$(eval $(autotools-package))
