# Kernel maintenance

Do this on every kernel bump.

1. Apply `patches/linux/*` in order to a scratch copy of the new tree with
   `patch -p1 --fuzz=0`. Regenerate any patch that needs fuzz or an offset;
   drop one only once its change is in the new tree.
2. Build the aic8800 driver against the new kernel. If the replayed series
   fails, look at what [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800)
   has added to `debian/patches/series` since the pin and move both aic8800
   packages to a commit whose series builds. A missing
   `fix-linux-<series>-build.patch` proves nothing by itself: upstream adds
   one only for a kernel that broke the build. While there —
   if the two skipped patches were refreshed (or line endings normalized),
   prefer dropping the skip over carrying it.
3. Check Armbian's DKMS version guard in
   [`extensions/radxa-aic8800.sh`](https://github.com/armbian/build/blob/main/extensions/radxa-aic8800.sh)
   and their kernel-bump PRs — the guard tells you which kernels upstream
   believes the driver builds against. **Never sync this package to their
   extension blindly:** Armbian compiles the source with `CONFIG_BLUEDROID`
   *unflipped*, i.e. with no working BlueZ Bluetooth.
4. Resolve the same defconfig + fragments against the old and the new tree
   and diff the two `.config`s for symbols the new kernel turns on by
   default. Audit each against the `compatible` strings in the board DTB
   and disable what nothing binds to. A driver can also take over
   a devicetree node between releases with no symbol changing, so compare
   which driver is bound to each proven device node before and after
   (`/sys/bus/platform/devices/*/driver`).
5. On both trees, list the symbols the defconfig and the fragments set
   that the resolved `.config` does not carry with the requested value.
   The list is never empty (about 110 entries: other-SoC options, and
   requests Kconfig legitimately overrides, e.g. `CONFIG_BT=y` → `m`), so
   compare the two: they must match apart from what the bump intends. A
   new entry is a renamed or re-parented symbol, dropped silently.
6. Decompile the old and new board DTBs (`dtc -I dtb -O dts`), normalise
   the phandle numbers, and diff. Every difference should trace to an
   upstream DTS change or a carried patch.
7. Rebuild and re-run the gate behind every validated-stack row the bump moved
   or whose proof rides on something it moved (see
   [validation.md](validation.md)). For a kernel bump: the base sequence at
   the top of the validated-stack table (boot → ethernet → A/B OTA + revert →
   watchdog → `fastrpc_test` 3/3), a UFS-module boot, the Venus decode
   smoke test, the QAIRT HTP run, any product-layer gates, and the three radio
   gates: WiFi STA association, `hci0` + BLE advertising (verify off-board,
   not just `ActiveInstances`), and a BLE scan/advertise/WiFi coexistence
   soak. A "last hardware-validated on" marker is cleared by replacing it,
   and any older proof date beside it, with the new dated proof; deleting
   the marker alone leaves the new version inside the old proof. A gate
   re-run only in part clears it only for that part: date what was re-run
   and keep the marker on the rest.
