# Kernel maintenance

The kernel is Qualcomm's qcom-next integration tree
([qualcomm-linux/kernel](https://github.com/qualcomm-linux/kernel)),
pinned by tag in `nerves_defconfig`
(`BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION`). qcom-next is force-pushed, so
always pin a `qcom-next-*` snapshot tag, never the branch. The tag to move
to is the one meta-qcom's `linux-qcom-next` recipe pins: that is the kernel
Qualcomm's own Yocto BSP builds for QCS6490.

## Tracking upstream (do this on every kernel bump)

1. Apply `patches/linux/*` in order to a scratch copy of the new tree with
   `patch -p1 --fuzz=0`. Regenerate any patch that needs fuzz or an
   offset; drop one only once its change is in the new tree. Today:
   - `0003` (sc7280 qmp-ufs HS-G4 PHY init table) is absent from mainline
     and qcom-next.
   - `0004` (`aspm-no-l1ss` on `&pcie1_port0`) works around the M.2 link
     dropping once L1.1 is allowed. Drop it only after an NVMe proves
     stable with L1.1 on the new tree.
2. Resolve `linux-7.3.defconfig` + `linux-hwdebug.config` against the old
   and the new tree and diff the two `.config`s for symbols the new kernel
   turns on by default. Audit each against the `compatible` strings in the
   board DTB and disable what nothing binds to. A driver can also take over
   a devicetree node between releases with no symbol changing, so compare
   which driver is bound to each proven device node before and after
   (`/sys/bus/platform/devices/*/driver`).
3. On both trees, list the symbols the defconfig and the fragment set that
   the resolved `.config` does not carry with the requested value. The list
   is never empty (other-SoC options, and requests Kconfig legitimately
   overrides), so compare the two: they must match apart from what the
   bump intends. A new entry is a renamed or re-parented symbol, dropped
   silently (7.3 did this to `CMA_SIZE_MBYTES`, `CRYPTO_DEV_QCOM_RNG` and
   the legacy iptables symbols; see the CHANGELOG history).
4. Decompile the old and new `qcom/qcs6490-thundercomm-rubikpi3.dtb`
   (`dtc -I dtb -O dts`), normalise the phandle numbers, and diff. Every
   difference should trace to an upstream DTS change or a carried patch.
5. Rebuild and re-run the gate behind every row of
   [validation.md](validation.md) the bump moved or whose proof rides on
   something it moved. For a kernel bump that is at least: boot to iex on
   `ttyMSM0`, Ethernet + USB3 (the `rubik-usb-fw` path), A → B → A OTA,
   watchdog, `fastrpc_test` 3/3, the QAIRT HTP run, the Venus decode smoke
   test (`test_src/`), WiFi scan + WPA2 association, the BT controller,
   NVMe probe and throughput, and the GPU/display probe. Replace a proof's
   date only for the part that was actually re-run.

## Pending

The next tag after `qcom-next-7.3-rc4-20261014` (`qcom-next-7.3-rc6-20261023`)
has not been taken yet; it follows the procedure above.
