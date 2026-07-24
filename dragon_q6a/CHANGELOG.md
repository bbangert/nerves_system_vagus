# Changelog

## v0.1.0

Initial release.

* Radxa Dragon Q6A (QCS6490) support: mainline kernel with the in-tree
  `qcom/qcs6490-radxa-dragon-q6a` device tree, EDK2 UEFI → GRUB2 (arm64-efi)
  boot chain with grubenv-driven A/B rootfs slots on a 5-partition GPT
  (config FAT, ESP, rootfs A/B squashfs, /data ext4), NVMe-first.
* AI foundation: linux-firmware qcom blobs plus the matched Dragon Q6A
  CDSP/ADSP firmware set with `.jsn` descriptors (target-local
  `dragon-q6a-firmware` package), fastrpc userspace (library, daemons,
  `fastrpc_test`) as a target-local package, and udev rules for
  fastrpc/dma_heap/video/dri device access. QAIRT is user-provisioned to
  `/data` and deliberately not part of the image.
