#!/bin/sh

set -e

# Create the Grub environment blocks (grub-editenv comes from host-grub2,
# a dependency of Buildroot's grub2 package)
grub-editenv $BINARIES_DIR/grubenv_a create
grub-editenv $BINARIES_DIR/grubenv_a set boot=0
grub-editenv $BINARIES_DIR/grubenv_a set validated=0
grub-editenv $BINARIES_DIR/grubenv_a set booted_once=0

grub-editenv $BINARIES_DIR/grubenv_b create
grub-editenv $BINARIES_DIR/grubenv_b set boot=1
grub-editenv $BINARIES_DIR/grubenv_b set validated=0
grub-editenv $BINARIES_DIR/grubenv_b set booted_once=0

cp $BINARIES_DIR/grubenv_a $BINARIES_DIR/grubenv_a_valid
grub-editenv $BINARIES_DIR/grubenv_a_valid set booted_once=1
grub-editenv $BINARIES_DIR/grubenv_a_valid set validated=1

cp $BINARIES_DIR/grubenv_b $BINARIES_DIR/grubenv_b_valid
grub-editenv $BINARIES_DIR/grubenv_b_valid set booted_once=1
grub-editenv $BINARIES_DIR/grubenv_b_valid set validated=1

# Copy everything that's needed to build firmware images over to the
# output directory so that it can be bundled with the system image.
#
# The GRUB EFI binary itself needs no staging step: Buildroot's grub2
# package (grub-mkimage, arm64-efi, prefix /EFI/BOOT) already installs it at
# $BINARIES_DIR/efi-part/EFI/BOOT/bootaa64.efi, which fwup.conf references
# directly. There is no BIOS boot.img stage-1 on UEFI.
cp $NERVES_DEFCONFIG_DIR/grub.cfg $BINARIES_DIR

# Overwrite the Buildroot-generated grub.cfg in the efi-part staging tree to
# avoid confusion -- fwup writes our grub.cfg onto the ESP either way.
if [ -d $BINARIES_DIR/efi-part/EFI/BOOT ]; then
    cp $NERVES_DEFCONFIG_DIR/grub.cfg $BINARIES_DIR/efi-part/EFI/BOOT/grub.cfg
fi

# Remove any Buildroot-generated grub artifacts from the target rootfs. Our
# grub.cfg/grubenv live in the ESP FAT filesystem at the beginning of the
# disk so that they exist across firmware updates.
rm -fr $TARGET_DIR/boot/grub

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR

# Create the fwup ops script for handling disk operations at runtime
# NOTE: revert.fw is the previous, more limited version of this. ops.fw is
#       backwards compatible.
mkdir -p $TARGET_DIR/usr/share/fwup
NERVES_SYSTEM=$BASE_DIR $HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw
