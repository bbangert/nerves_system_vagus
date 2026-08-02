# Flashing the Radxa Dragon Q6A (EDL runbook)

How to write a `nerves_system_dragon_q6a` full-disk image to the board's
NVMe over EDL (Qualcomm Emergency Download mode). Distilled from the
2026-07-23 bring-up session that flashed Armbian this way (full war story:
`edl.md` in the vagus repo) — every step below was either proven in that
session or is the one documented fix for a failure we hit.

## Prerequisites

### SPI NOR firmware (one-time, user-flashed)

The Q6A boots EDK2 UEFI from a separate 32 MiB SPI NOR (PBL → XBL → TZ →
UEFI). The Nerves image assumes a working UEFI on SPI NOR that:

- scans GPT disks and runs `\EFI\BOOT\BOOTAA64.EFI` from the ESP
  (removable-media fallback path — no NVRAM entry needed), and
- publishes the board devicetree to the OS via the EFI configuration table
  (`/sys/firmware/fdt`; proven by RadxaOS's kernel 6.18.2-3 booting with no
  explicit `devicetree` line).

Flash/update it from Radxa's **flat_build** SPI firmware package per
[Radxa's SPI firmware docs](https://docs.radxa.com/en/dragon/q6a/low-level-dev/spi-fw).
**Pin/record the version you flashed** alongside test results — boot-order
and DT behavior are firmware-dependent. The firmware version validated with
this system gets recorded in `dragon_q6a/README.md`'s VERSIONS table.

### Host setup (one-time)

Two host-side fixes, both learned the hard way:

```bash
# 1. udev rule: makes 05c6:9008 world-accessible (fixes pyusb
#    "Permission denied", including *under sudo* inside containers).
sudo tee /etc/udev/rules.d/51-edl-qdl.rules <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="05c6", ATTR{idProduct}=="9008", MODE="0666", TAG+="uaccess"
EOF
sudo udevadm control --reload && sudo udevadm trigger
# Applies only on (re-)enumeration — replug the data cable afterwards.

# 2. Blacklist qcserial. It binds 05c6:9008 on enumeration and eats the
#    one-shot Sahara HELLO, after which edl-ng CANNOT recover (its error:
#    "04000000100000000D00000001000000" + "Detected device mode: Unknown").
#    A one-off unbind does NOT stick (re-binds on re-enumeration).
# Normal distro:
echo 'blacklist qcserial' | sudo tee /etc/modprobe.d/qcserial-blacklist.conf
# rpm-ostree (Bluefin/Silverblue):
sudo rpm-ostree kargs --append=modprobe.blacklist=qcserial && sudo systemctl reboot
# Session-only alternative (right before EDL entry): sudo modprobe -r qcserial
```

Tools: [`edl-ng`](https://github.com/strongtz/edl-ng) **latest release**
(1.0.0 predates the Q6A), plus optionally
[`bkerler/edl`](https://github.com/bkerler/edl) for the fallback path.
Loader: `prog_firehose_ddr.elf` from Radxa's flat_build package.

Prefer a direct root-hub USB port over hub chains.

## EDL entry (exact sequence — replug alone is NOT enough)

1. Unplug **both** power and the USB-A↔A data cable.
2. Hold the **EDL button** (next to the headphone jack).
3. Apply **power** while holding.
4. Connect the data cable; release the button after a few seconds.
5. Verify: `lsusb | grep 9008` → `05c6:9008 ... (QDL mode)`.

## Build and flash the image

```bash
# In the firmware project (MIX_TARGET=dragon_q6a):
mix firmware
fwup -a -t complete -i _build/dragon_q6a_dev/nerves/images/<app>.fw -d dragon_q6a.img
# (the fwup task extends the file so the backup GPT lands at the disk-tail
# position for the *image*; Firehose writes it verbatim)

# Path A — qcserial blacklisted (standalone edl-ng):
./edl-ng --loader prog_firehose_ddr.elf --memory nvme write-sector 0 dragon_q6a.img
```

Expected: `Detected device mode: Sahara` (fresh entry) → upload → write at
~33 MiB/s.

**Path B — recovery when edl-ng reports `mode: Unknown`** (Sahara HELLO
was stolen; board is fine). The Firehose programmer persists in DDR across
tool invocations, so let bkerler/edl do the Sahara work, then hand off:

```bash
# 1. bkerler/edl uploads the loader as a side effect of printgpt and
#    leaves Firehose running (mkdir -p logs first; use /usr/bin/python3):
python3 ./edl.py --loader prog_firehose_ddr.elf --memory nvme printgpt --debugmode
# 2. WITHOUT power-cycling or replugging, edl-ng finds the live session:
./edl-ng --loader prog_firehose_ddr.elf --memory nvme write-sector 0 dragon_q6a.img
# Expected: "Detected device mode: Firehose" immediately.
```

Exit EDL: unplug data → unplug power → replug power without the button.
No soft shutdown exists in EDL; once Firehose acknowledges the write,
pulling power is clean.

## First boot

Serial console is on the GENI debug UART (`ttyMSM0`, 115200n8) — GRUB's
slot banner and the IEx console both land there. First boot formats
`/data` (p5) at the image's 512 MiB — EDL writes the pre-generated image
verbatim, so fwup's `expand=true` didn't get to run. Grow `/data` to the
full disk once the board is up:

```sh
fwup -t expand-data -d /dev/rootdisk0 /usr/share/fwup/ops.fw
reboot
resize2fs /dev/rootdisk0p5
```

Find the device's IP from the router's DHCP table; NervesSSH is on
port 22 (`ssh <ip>`).

## Diagnosis cheat sheet

| Observation | Meaning | Action |
|---|---|---|
| No `05c6:9008` in `lsusb` | Not in EDL — replug doesn't re-enter it | Full entry sequence, button held while power applied |
| `Driver=qcserial` in `lsusb -t` | Sahara HELLO being stolen | Blacklist; one-off unbind won't persist |
| `0400…0D…01` + `mode: Unknown` from edl-ng | Poisoned Sahara session | Path B, or clean EDL re-entry after blacklisting |
| `Detected device mode: Firehose` immediately | Loader already live in DDR | Good state — proceed straight to write |
| pyusb `Permission denied` (even sudo, container) | udev perms | udev rule above + replug, run unprivileged |
| Board doesn't boot after a successful write | Wrong sector-size variant or compressed image flashed | 512-byte image for NVMe; decompress first |

## UFS variant ("Fork A" — same `.fw`, regenerated GPT)

> Status: DEVICE-PROVEN 2026-08-02 on a 128 GB module (119.2 GiB usable
> after the 4 GiB WriteBooster carve-out): provisioning, flash, boot,
> ethernet, /data at full size on first boot, A/B OTA cycle. Boot order
> with NVMe and UFS both fitted remains unverified.

The Q6A's UFS module reports **4096-byte logical sectors**, and fwup is
hardwired to 512-byte blocks in both its GPT writer and its FatFs code.
That turns out to matter only for the GPT structures themselves: EDK2's
FAT driver and GRUB are BPB/byte-driven (a 512-BPB FAT mounts fine on a
4Kn device), the on-device A/B upgrade tasks address everything by
MiB-aligned byte offsets, and the kernel only needs a valid GPT for
`root=PARTUUID=`. So there is **no separate `_4096` fwup config**: the
`.fw` file and every on-device code path are identical between NVMe and
UFS. The only delta is the EDL disk image, whose GPT
`dragon_q6a/tools/mk_ufs_image.py` regenerates for 4096-byte LBAs (full
rationale in its docstring).

Kernel prerequisite: UFS only links up with `patches/linux/0002-*`
(board DTS enable, Gear-4 Rate-A, ICE off) and `0003-*` (sc7280 HS-G4
PHY init fix) in the system build. The DTB is shared by both variants —
on the NVMe board the ufshcd probe just fails cleanly when no module is
fitted.

### Generate the UFS kit

```bash
# Same .fw and 512-LBA image as the NVMe flow:
mix firmware
fwup -a -t complete -i _build/dragon_q6a_dev/nerves/images/<app>.fw -d dragon_q6a.img

# Transform: 512-LBA GPT -> 4Kn GPT, data partition sized to the module.
# --disk-bytes MUST be the module's exact capacity (sectors x 4096 from
# printgpt below) — the backup-GPT write position depends on it.
dragon_q6a/tools/mk_ufs_image.py --input dragon_q6a.img \
    --disk-bytes <module bytes> --out dragon_q6a_ufs
```

This emits two pieces plus the exact `edl-ng` commands to run:
`dragon_q6a_ufs.img` (MBR + primary GPT + partition data) and
`dragon_q6a_ufs-backup-gpt.bin` (written at the disk-tail LBA it
prints). A `--full` mode emits a single sparse full-disk image instead,
but EDL-writing 100+ GiB is slow; prefer the two-piece flow.

### Flash

First confirm EDL sees the module and capture its geometry (this is the
Phase 4.1 spike — record the output):

```bash
./edl-ng --loader prog_firehose_ddr.elf --memory ufs printgpt
# Confirms --memory ufs access, LUN topology, sector size (expect 4096)
# and total sectors (x 4096 = the --disk-bytes value above).
```

**Blank-module caveat:** a factory-blank UFS module has no LUN
configured, so reads fail until one-time provisioning — symptoms are
bkerler-edl's `"Failed to open the UFS Device"` or edl-ng ACKing the
Firehose configure but then warning `Storage info JSON not found` and
timing out on the read. Provision with the board's official descriptor
([`Kodiak/radxa-dragon-q6a/provision_ufs31_lun0_only.xml`](https://github.com/armbian/qcombin/blob/main/Kodiak/radxa-dragon-q6a/provision_ufs31_lun0_only.xml)
from Armbian's qcombin repo) — single LUN 0 grown to fill the module,
4096-byte logical blocks, `bConfigDescrLock=0` (descriptor stays
rewritable):

```bash
# Re-enter EDL fresh first (full button sequence) — a timed-out
# Firehose session is not reusable.
./edl-ng --loader prog_firehose_ddr.elf --memory ufs provision provision_ufs31_lun0_only.xml
# Then power-cycle EDL again and re-run printgpt to capture geometry.
```

```bash
./edl-ng --loader prog_firehose_ddr.elf --memory ufs \
    write-sector 0 dragon_q6a_ufs.img --lun 0
./edl-ng --loader prog_firehose_ddr.elf --memory ufs \
    write-sector <backup LBA printed by the tool> dragon_q6a_ufs-backup-gpt.bin --lun 0
```

EDL entry/exit and Path B recovery are identical to the NVMe flow above.

### First boot differences vs NVMe

- **Do NOT run the `expand-data` recipe.** fwup's `gpt_write()` hardcodes
  512-LBA math and would corrupt the 4Kn GPT. `mk_ufs_image.py` already
  sized `/data` (p5) to fill the module at generation time — there is
  nothing to expand.
- Firmware boot order with **both** NVMe and UFS populated is unverified
  (Phase 4.3 documentation item) — on the UFS gate board, keep NVMe
  absent or blank.
