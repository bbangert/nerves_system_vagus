# Installing Vagus on the Home Assistant Green

How to put a Vagus firmware (`MIX_TARGET=ha_green`) on a Home Assistant
Green. The board support and its hardware validation record are in
[ha_green/base/README.md](../ha_green/base/README.md); this page is the
procedure.

The Green's own first-stage loader (eMMC LBA 64-16383 and the SPI NOR) is
never written by anything here. There is no maskrom tooling and no serial
console in this workflow, so a damaged loader could not be repaired.

## 1. Write the SD card

Build the firmware (`mix firmware`), then write a card with the `complete`
task, for example `mix burn`, or

```sh
fwup -a -d /dev/sdX -t complete -i <product>.fw
```

`complete` lays down the whole disk layout, including our U-Boot at LBA 16384,
which is what the board's loader looks for. A card burned directly gets its
data partition sized to the card; a card written from an image file keeps a
512 MiB data partition. Use `complete` only on an SD card or an image file:
it refuses a destination that holds an installed eMMC's `medium.mmc`, and you
must never aim it at `/dev/mmcblk0` of the Green by hand.

## 2. Boot from the card

Put the card in the Green and power it on. The board's loader boots our
U-Boot from the card when the card carries our image, and the system comes up
from the SD card. The hostname is `nerves-` plus the last four characters of
the board serial.

An SD card with our image always wins over the eMMC, whatever the eMMC holds.
That is the rescue path: with the card in, the board boots the card; take the
card out and it boots the eMMC.

### LED codes

With no console, the user LED shows how far a boot got:

| User LED | Meaning |
| --- | --- |
| solid | Our U-Boot reached its boot script |
| heartbeat | Our kernel is running |
| off for about 10 s, then solid again, repeating | The kernel failed to load; U-Boot retries |
| a reset about every 15 s | Kernel panic loop |

If stock Home Assistant OS comes up with the card inserted, the board's
loader did not take our image from the card.

## 3. Install to the eMMC

Installing replaces Home Assistant OS on the eMMC: the partition table, the
system and all data. Back up first.

Copy the same `.fw` the card was written from to the running, SD-booted
system and run, there, the one install command:

```sh
green-install-emmc <path-to.fw>
```

It must be that build: the final check compares the eMMC's U-Boot with the
card's, so a different build ends in `FAIL` even though the install
completed. The tool refuses, writing nothing, unless the system is running
from the SD card, the eMMC is the expected non-removable MMC device and is
unmounted, an `RKNS` loader header sits at eMMC LBA 64, the `.fw` is for
platform `ha_green`, and the card carries our U-Boot. A refusal reads
`green-install-emmc: REFUSED: <reason>; nothing was written to the eMMC.`
If there is no `RKNS` header (a blank or non-stock eMMC) this system cannot
be installed on that unit; restore stock first (below).

A good run ends with:

```
eMMC GPT: written and read back identical
loader area: unchanged
FIT window: identical
eMMC GPT: unchanged by the install
PASS
```

Anything else ends with `FAIL: do not reboot into the eMMC; no repair was
attempted`. The tool can simply be run again after an interruption; the card
stays bootable throughout.

Then remove the card and reboot. Without the card, the board's loader falls
through to our U-Boot on the eMMC.

There is no other way to write the eMMC. `green-install-emmc` is the only
eMMC writer, and fwup itself never writes the eMMC's partition table.

## What is never written

| Never written | Why |
| --- | --- |
| eMMC LBA 64-16383 | The stock first-stage loader. |
| The SPI NOR | May hold the factory loader that runs first. |

U-Boot is not part of an over-the-air upgrade: upgrades write only the boot,
root filesystem and state partitions. A new U-Boot arrives only through
`complete` or `green-install-emmc`.

## Restoring stock Home Assistant OS

Use the official Home Assistant Green installer card. It rewrites the whole
eMMC, loader included, with Nabu Casa's own images; data on the eMMC is lost.
This system provides no `dd` path back to stock of its own.
