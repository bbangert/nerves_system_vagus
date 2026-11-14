#!/usr/bin/env python3
"""Boot-script matrix for the Home Assistant Green, run in U-Boot's sandbox.

Each scenario starts from fresh disk images and boots three times in a row.
Expectations come from `model()`, an independent restatement of the rules
in uboot/README.md, never from the script under test.
"""

import argparse
import hashlib
import os
import random
import re
import shutil
import subprocess
import sys
import zlib

BLK = 512
ENV_LBA, ENV_BLOCKS, ENV_SIZE = 0x8000, 0x100, 0x20000
FIT_LBA = 0x4000
# Shrunk with fwup's define() overrides; offsets stay production's.
SIZES = {"BOOT_PART_COUNT": "32768", "ROOTFS_A_PART_COUNT": "2048",
         "APP_PART_COUNT": "2048"}
FAT_LBA, FAT_BLOCKS = 34816, 32768
# 73728 blocks of layout plus fwup's backup GPT, rounded up to whole MiB.
DISK_BLOCKS = 75776
REGIONS = [  # (name, first LBA, end LBA)
    ("gpt", 0, 64),
    ("loader", 64, 16384),
    ("fit", 16384, 32768),
    ("state", ENV_LBA, ENV_LBA + ENV_BLOCKS),
    ("p1rest", ENV_LBA + ENV_BLOCKS, FAT_LBA),
    ("fat", FAT_LBA, FAT_LBA + FAT_BLOCKS),
    ("rest", FAT_LBA + FAT_BLOCKS, DISK_BLOCKS),
]
DEFAULTS = {"nerves_fw_active": "a", "nerves_fw_validated": "1",
            "nerves_fw_booted": "0", "nerves_fw_autovalidate": "0",
            "nerves_watchdog": "0"}
CRUMBS = ["uboot-vars.txt", "uboot-fdt.dtb", "ramoops.bin"]
RAMOOPS = (0x110000, 0xF0000)
# /chosen/u-boot,spl-boot-device as a 2026.04 SPL writes it: the ofpath of
# the controller it loaded U-Boot from (sdmmc0 = SD, sdhci = eMMC).
SPL_SD = "/mmc@fe2b0000"
SPL_EMMC = "/mmc@fe310000"
# A property with no value, as opposed to one holding "".
SPL_NOVALUE = object()


def env_parse(block):
    """Returns the variables of a CRC-valid state block, else None."""
    crc = int.from_bytes(block[:4], "little")
    if zlib.crc32(block[4:ENV_SIZE]) != crc:
        return None
    out = {}
    for entry in block[4:ENV_SIZE].split(b"\0\0", 1)[0].split(b"\0"):
        if entry:
            k, _, v = entry.decode().partition("=")
            out[k] = v
    return out


def env_build(variables):
    """A dict, or a list of (key, value) pairs for blocks with repeated or
    empty keys; an empty value is U-Boot's delete entry."""
    pairs = variables.items() if isinstance(variables, dict) else variables
    data = b"".join(f"{k}={v}".encode() + b"\0" for k, v in pairs)
    data = data + b"\0"
    data = data + b"\0" * (ENV_SIZE - 4 - len(data))
    return zlib.crc32(data).to_bytes(4, "little") + data


class Disk:
    def __init__(self, path):
        self.path = path

    def read(self, lba, blocks):
        with open(self.path, "rb") as f:
            f.seek(lba * BLK)
            return f.read(blocks * BLK)

    def write(self, lba, data):
        with open(self.path, "r+b") as f:
            f.seek(lba * BLK)
            f.write(data)

    def state(self):
        return env_parse(self.read(ENV_LBA, ENV_BLOCKS))

    def set_state(self, variables):
        self.write(ENV_LBA, env_build(variables))

    def hashes(self):
        out = {}
        with open(self.path, "rb") as f:
            for name, first, end in REGIONS:
                f.seek(first * BLK)
                out[name] = hashlib.sha256(f.read((end - first) * BLK)).hexdigest()
        return out


class Fixture:
    """Builds the base images once with fwup, the way `complete` does."""

    def __init__(self, args):
        self.args = args
        self.dir = os.path.join(args.work, "fixture")
        self.dtbs = {}
        os.makedirs(self.dir, exist_ok=True)
        envbin = os.path.join(self.dir, "uboot-env.bin")
        run([args.mkenvimage, "-s", str(ENV_SIZE), "-o", envbin, args.env])
        self.images = {}
        for medium in ("sd", "emmc"):
            self.images[medium] = self.complete(medium, envbin)
        self.images["stock"] = self.stock()

    def complete(self, medium, envbin):
        d = os.path.join(self.dir, medium)
        os.makedirs(d, exist_ok=True)
        for slot in "ab":
            with open(os.path.join(d, f"Image.{slot}"), "wb") as f:
                f.write(f"IMAGE.{slot}@{medium}".encode().ljust(64, b"\0"))
            with open(os.path.join(d, f"dtb.{slot}"), "wb") as f:
                f.write(f"DTB.{slot}@{medium}".encode().ljust(64, b"\0"))
        with open(os.path.join(d, "u-boot.itb"), "wb") as f:
            f.write(bytes.fromhex("d00dfeed") + b"test FIT".ljust(4092, b"\0"))
        conf = os.path.join(d, "disk.conf")
        with open(conf, "w") as f:
            f.write(FWUP_CONF.format(repo=self.args.repo, dir=d, envbin=envbin,
                                     gpt="gpt-sd" if medium == "sd" else "gpt-emmc"))
        env = dict(os.environ, NERVES_SYSTEM="/nonexistent", NERVES_SDK_VERSION="0.0.0-test",
                   NERVES_PROVISIONING=os.path.join(self.args.repo, "fwup_include/provisioning.conf"),
                   NERVES_SDK_IMAGES=self.args.repo, NERVES_SERIAL_NUMBER="TESTSERIAL", **SIZES)
        fw = os.path.join(d, "disk.fw")
        img = os.path.join(d, "disk.img")
        run(["fwup", "-c", "-f", conf, "-o", fw], env=env)
        if os.path.exists(img):
            os.unlink(img)
        run(["fwup", "-a", "-q", "-d", img, "-i", fw, "-t", "complete"], env=env)
        size = os.path.getsize(img)
        if size > DISK_BLOCKS * BLK:
            sys.exit(f"{img}: {size} bytes, more than the {DISK_BLOCKS * BLK} the matrix models")
        # The sandbox MMC reports whole MiB.
        os.truncate(img, DISK_BLOCKS * BLK)
        return img

    def stock(self):
        """Stand-in for a stock HAOS eMMC: noise, a loader, a FIT, no state."""
        img = os.path.join(self.dir, "stock.img")
        rnd = random.Random(1)
        with open(img, "wb") as f:
            for _ in range(DISK_BLOCKS // 2048):
                f.write(rnd.randbytes(2048 * BLK))
        d = Disk(img)
        d.write(64, b"RKNS")
        d.write(FIT_LBA, bytes.fromhex("d00dfeed"))
        return img

    def dtb(self, sd_present, spl_boot_device):
        key = (sd_present, spl_boot_device)
        if key in self.dtbs:
            return self.dtbs[key]
        name = f"test-{int(sd_present)}-{len(self.dtbs)}"
        if spl_boot_device is None:
            chosen = ""
        elif spl_boot_device is SPL_NOVALUE:
            chosen = "u-boot,spl-boot-device;"
        else:
            chosen = f'u-boot,spl-boot-device = "{spl_boot_device}";'
        dts = os.path.join(self.dir, name + ".dts")
        with open(dts, "w") as f:
            f.write(TEST_DTS.format(
                emmc=os.path.join(self.args.work, "emmc.img"),
                sd=os.path.join(self.args.work, "sd.img"),
                sd_status="okay" if sd_present else "disabled",
                chosen=chosen))
        pre = dts + ".pre"
        src, build = self.args.src, self.args.build
        run(["cpp", "-P", "-nostdinc", "-undef", "-D__DTS__", "-D__ASSEMBLY__", "-x", "assembler-with-cpp",
             "-I", os.path.join(src, "arch/sandbox/dts"), "-I", os.path.join(src, "include"),
             "-I", os.path.join(build, "include"), "-I", os.path.join(src, "dts/upstream/include"),
             "-I", os.path.join(src, "arch/sandbox/include"), "-o", pre, dts])
        out = os.path.join(self.dir, name + ".dtb")
        run([self.args.dtc, "-q", "-I", "dts", "-O", "dtb", "-o", out, pre])
        self.dtbs[key] = out
        return out


FWUP_CONF = """
include("{repo}/fwup_include/fwup-common.conf")
file-resource uboot-env.bin {{ host-path = "{envbin}" }}
file-resource Image.a {{ host-path = "{dir}/Image.a" }}
file-resource Image.b {{ host-path = "{dir}/Image.b" }}
file-resource dtb.a {{ host-path = "{dir}/dtb.a" }}
file-resource dtb.b {{ host-path = "{dir}/dtb.b" }}
file-resource u-boot.itb {{ host-path = "{dir}/u-boot.itb" }}
uboot-environment uboot-env {{
    block-offset = ${{UBOOT_ENV_OFFSET}}
    block-count = ${{UBOOT_ENV_COUNT}}
}}
task complete {{
    on-init {{
        gpt_write({gpt})
        fat_mkfs(${{BOOT_PART_OFFSET}}, ${{BOOT_PART_COUNT}})
    }}
    on-resource Image.a {{ fat_write(${{BOOT_PART_OFFSET}}, "Image.a") }}
    on-resource Image.b {{ fat_write(${{BOOT_PART_OFFSET}}, "Image.b") }}
    on-resource dtb.a {{ fat_write(${{BOOT_PART_OFFSET}}, "rk3566-ha-green.a.dtb") }}
    on-resource dtb.b {{ fat_write(${{BOOT_PART_OFFSET}}, "rk3566-ha-green.b.dtb") }}
    on-resource uboot-env.bin {{
        raw_write(${{UBOOT_ENV_OFFSET}})
        include("{repo}/fwup_include/initial-env.conf")
    }}
    on-resource u-boot.itb {{
        raw_memset(${{FIT_OFFSET}}, ${{FIT_COUNT}}, 0x00)
        raw_write(${{FIT_OFFSET}})
    }}
    on-finish {{ raw_memset(${{APP_PART_LAST_OFFSET}}, 1, 0xff) }}
}}
"""

TEST_DTS = """
#include "sandbox.dts"
/ {{
    aliases {{
        mmc0 = &test_emmc;
        mmc1 = &test_sd;
    }};
    test_emmc: mmc-emmc {{
        compatible = "sandbox,mmc";
        filename = "{emmc}";
        non-removable;
    }};
    test_sd: mmc-sd {{
        compatible = "sandbox,mmc";
        filename = "{sd}";
        status = "{sd_status}";
    }};
}};
&{{/chosen}} {{
    {chosen}
}};
&{{/leds}} {{
    led-user {{
        gpios = <&gpio_a 3 0>;
        label = "user";
    }};
}};
&alarm_wdt {{
    status = "disabled";
}};
"""


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout


# Disk kinds: what is on a disk before the first boot.
#   ours     our `complete` image (FIT + valid state)
#   corrupt  ours, one byte of the state block flipped (bad CRC)
#   nostate  ours, state block zeroed
#   erased   ours, state block 0xff
#   dataonly ours without FIT magic (a data card the SPL skips)
#   stock    stock HAOS stand-in (FIT magic, no state, no FAT)
def make_disk(fixture, kind, medium, path):
    base = fixture.images["stock"] if kind == "stock" else fixture.images[medium]
    shutil.copyfile(base, path)
    d = Disk(path)
    if kind == "corrupt":
        b = bytearray(d.read(ENV_LBA, 1))
        b[100] ^= 0x01
        d.write(ENV_LBA, bytes(b))
    elif kind == "nostate":
        d.write(ENV_LBA, b"\0" * ENV_SIZE)
    elif kind == "erased":
        d.write(ENV_LBA, b"\xff" * ENV_SIZE)
    elif kind == "dataonly":
        d.write(FIT_LBA, b"\0" * BLK)
    return d


def has_fit(kind):
    return kind != "dataonly"


def has_fat(kind):
    return kind != "stock"


def model(sd_kind, emmc_kind, sd_state, emmc_state, spl=None):
    """The spec: which disk, which slot, whether and what U-Boot saves."""
    sd_fit = sd_kind is not None and has_fit(sd_kind)
    if spl == SPL_EMMC:
        disk, by = 0, "spl"
    elif spl == SPL_SD and sd_kind is not None:
        disk, by = 1, "spl"
    else:
        disk, by = (1 if sd_fit else 0), "probe"
    kind = sd_kind if disk == 1 else emmc_kind
    stored = sd_state if disk == 1 else emmc_state
    env = dict(DEFAULTS, cmdline="")
    if stored is not None:
        env.update(stored)
    save = False
    if env["nerves_fw_booted"] == "1":
        if env["nerves_fw_validated"] == "0":
            env["nerves_fw_active"] = "a" if env["nerves_fw_active"] == "b" else "b"
            env["nerves_fw_validated"] = "1"
            save = True
    else:
        env["nerves_fw_booted"] = "1"
        if env["nerves_fw_autovalidate"] == "1":
            env["nerves_fw_validated"] = "1"
        save = True
    slot = "b" if env["nerves_fw_active"] == "b" else "a"
    return {
        "disk": disk,
        "state": "ok" if stored is not None else "none",
        "slot": slot,
        "boots": has_fat(kind),
        "save": save and stored is not None,
        "new": {k: env[k] for k in ("nerves_fw_active", "nerves_fw_validated",
                                    "nerves_fw_booted")},
        "watchdog": env["nerves_watchdog"] == "1",
        "cmdline": env["cmdline"].split(),
        "medium": "sd" if disk == 1 else "emmc",
        "by": by,
        "sd_fit": "present" if sd_fit else "absent",
        # What uboot-vars.txt records; a "" property reads back as hex.
        "spl": ("absent" if spl is None else "empty" if spl is SPL_NOVALUE
                else None if spl == "" else spl),
    }


def parse_md(lines):
    data = b""
    for line in lines:
        m = re.match(r"^[0-9a-f]{8}: ((?:[0-9a-f]{2} ?)+)", line)
        if m:
            data += bytes.fromhex(m.group(1).replace(" ", ""))
    return data


def parse_mdl(lines):
    words = []
    for line in lines:
        m = re.match(r"^[0-9a-f]{8}: ((?:[0-9a-f]{8} ?)+)", line)
        if m:
            words += [int(w, 16) for w in m.group(1).split()]
    return words


def parse_boot(out):
    lines = [re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", l).rstrip() for l in out.splitlines()]
    res = {"outcome": "none"}
    sections = {}
    current = None
    for line in lines:
        m = re.match(r"^@@(BOOT|RESET) disk=(\S*) (?:slot=(\S*) )?state=(\S*)", line)
        if m:
            res.update(outcome=m.group(1).lower(), disk=m.group(2), slot=m.group(3),
                       state=m.group(4))
            current = None
            continue
        if line.startswith("@@ARGS "):
            res["bootargs"] = line[7:]
            continue
        m = re.match(r"^@@(KERNEL|DTB|WDT|LED)$", line)
        if m:
            current = m.group(1)
            sections[current] = []
            continue
        if current:
            sections[current].append(line)
    if "KERNEL" in sections:
        res["kernel"] = parse_md(sections["KERNEL"]).split(b"\0")[0].decode(errors="replace")
    if "DTB" in sections:
        res["dtb"] = parse_md(sections["DTB"]).split(b"\0")[0].decode(errors="replace")
    if "WDT" in sections:
        res["wdt"] = parse_mdl(sections["WDT"])
    if "LED" in sections:
        res["led"] = "on" if any(re.search(r"\bon\b", l) for l in sections["LED"]) else "off"
    return res


class Runner:
    def __init__(self, args, fixture):
        self.args = args
        self.fixture = fixture
        self.emmc = os.path.join(args.work, "emmc.img")
        self.sd = os.path.join(args.work, "sd.img")

    def boot(self, sd_present, spl_boot_device, memfile=None):
        cmd = [self.args.uboot, "-d", self.fixture.dtb(sd_present, spl_boot_device)]
        if memfile:
            cmd += ["-m", memfile]
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, errors="replace", timeout=20, cwd=self.args.work)
            out = r.stdout + r.stderr
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            out += "\n@@TIMEOUT"
        return out

    def fat_files(self, sd_present):
        """Lists both FATs and copies the SD's breadcrumbs out with U-Boot itself."""
        outdir = os.path.join(self.args.work, "crumbs")
        shutil.rmtree(outdir, ignore_errors=True)
        os.makedirs(outdir)
        cmds = ["echo @@EMMC", "fatls mmc 0:2"]
        if sd_present:
            cmds += ["echo @@SD", "fatls mmc 1:2"]
            for name in CRUMBS:
                cmds.append(f"if fatload mmc 1:2 0x1000000 {name}; then save hostfs - 0x1000000 "
                            f"{outdir}/{name} ${{filesize}}; fi")
        r = subprocess.run([self.args.uboot, "-d", self.fixture.dtb(sd_present, None),
                            "-c", "; ".join(cmds)], stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, errors="replace", timeout=60)
        files = {"emmc": set(), "sd": set()}
        where = None
        for line in r.stdout.splitlines():
            line = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip()
            if line == "@@EMMC":
                where = "emmc"
            elif line == "@@SD":
                where = "sd"
            elif where:
                m = re.match(r"^\d+\s+(\S+)$", line)
                if m:
                    files[where].add(m.group(1))
        return files, outdir


def scenarios():
    kinds_sd = [None, "ours", "corrupt", "nostate", "erased", "dataonly"]
    kinds_emmc = ["stock", "ours", "corrupt", "nostate"]
    for sd in kinds_sd:
        for emmc in kinds_emmc:
            yield {"name": f"sd={sd or 'absent'} emmc={emmc}", "sd": sd, "emmc": emmc,
                   "spl": SPL_SD if sd == "ours" and emmc == "ours" else None}
    yield from spl_hints()
    ab = [
        ("upgrade->b, validated", "b", ["validate", None, None]),
        ("upgrade->b, never validated", "b", [None, None, None]),
        ("upgrade->a, never validated", "a", [None, None, None]),
        ("upgrade->a, validated", "a", ["validate", None, None]),
        ("upgrade->b, autovalidate", "b+auto", [None, None, None]),
    ]
    for label, target, between in ab:
        for sd, emmc in (("ours", "stock"), (None, "ours")):
            yield {"name": f"{label} on {'SD' if sd else 'eMMC'}", "sd": sd, "emmc": emmc,
                   "upgrade": target, "between": between}
    yield {"name": "watchdog enabled (SD)", "sd": "ours", "emmc": "stock",
           "edit": {"nerves_watchdog": "1"}}
    yield {"name": "ramoops dumped (SD)", "sd": "ours", "emmc": "stock", "ramoops": True}
    yield {"name": "stale U-Boot vars in block (eMMC)", "sd": None, "emmc": "ours",
           "edit": {"nerves_disk": "1", "bootargs": "root=/dev/bogus", "ver": "U-Boot 1999.01",
                    "nerves_go": "echo POISON", "nerves_owned": "bootcmd",
                    "nerves_state": "ok", "kernel_addr_r": "0x0"}}
    yield from hostile_blocks()


def spl_hints():
    """The SPL's own word on where it loaded U-Boot from beats the probe; a
    value that is not exactly one of the two paths is no word at all."""
    # The SD's FIT still has its magic but the SPL rejected it and loaded
    # the eMMC's: the eMMC must boot and the card stay untouched.
    yield {"name": "spl=eMMC sd=ours (rejected FIT)", "sd": "ours", "emmc": "ours", "spl": SPL_EMMC}
    yield {"name": "spl=eMMC sd=dataonly", "sd": "dataonly", "emmc": "ours", "spl": SPL_EMMC}
    yield {"name": "spl=eMMC sd=absent", "sd": None, "emmc": "ours", "spl": SPL_EMMC}
    yield {"name": "spl=SD sd=ours emmc=stock", "sd": "ours", "emmc": "stock", "spl": SPL_SD}
    yield {"name": "spl=SD sd=absent", "sd": None, "emmc": "ours", "spl": SPL_SD}
    odd = [("upper", "/mmc@FE2B0000"), ("zero", "/mmc@0fe310000"), ("other", "/sdhci@fe310000"),
           ("prefix", SPL_SD + "x"), ("emptystr", ""), ("novalue", SPL_NOVALUE)]
    for label, value in odd:
        yield {"name": f"spl={label} sd=ours", "sd": "ours", "emmc": "ours", "spl": value}
        yield {"name": f"spl={label} sd=absent", "sd": None, "emmc": "ours", "spl": value}
    for where, sd, emmc, spl, label in (("SD", "ours", "ours", SPL_SD, "SD"),
                                        ("eMMC", "ours", "ours", SPL_EMMC, "eMMC"),
                                        ("eMMC", "dataonly", "ours", None, "absent")):
        yield {"name": f"block sets disk choice, spl={label} ({where})",
               "sd": sd, "emmc": emmc, "spl": spl, "on": "sd" if where == "SD" else "emmc",
               "edit": {"nerves_spl_boot_device": SPL_SD if spl != SPL_SD else SPL_EMMC,
                        "nerves_disk_by": "spl" if spl is None else "probe",
                        "nerves_sd_fit": "absent" if sd == "ours" else "present",
                        "nerves_disk": "1" if where == "eMMC" else "0"}}


def hostile_blocks():
    """CRC-valid blocks that try to make U-Boot write the other disk, or a
    partial import that tries to steer the boot. `malformed`: the block must
    count as absent (slot A, no save); otherwise it is imported normally and
    only the script's own variables are put back."""
    for where, sd, emmc, other in (("SD", "ours", "stock", 0), ("eMMC", "dataonly", "ours", 1)):
        on = "sd" if where == "SD" else "emmc"
        poison = {"nerves_crumbs": f"mmc dev {other}; mmc write 0x12000000 0x8000 0x1",
                  "nerves_save": f"mmc dev {other}; mmc write ${{nerves_state_addr}} 0x40 0x10",
                  "nerves_go": f"mmc dev {other}; mmc write 0x12000000 0x4000 0x1; poweroff"}
        base = {"sd": sd, "emmc": emmc, "on": on}
        yield dict(base, name=f"empty key after poisoned code ({where})", edit=poison,
                   post=[("", "x")], malformed=True)
        yield dict(base, name=f"empty key first ({where})", pre=[("", "x")],
                   edit=dict(poison, nerves_fw_active="b", nerves_fw_booted="1",
                             nerves_fw_validated="0"), malformed=True)
        yield dict(base, name=f"stash moved, disk {other} ({where})",
                   edit={"nerves_disk": str(other), "nerves_stash_addr": "0x10000000"})
        yield dict(base, name=f"stash moved, ver+fdt deleted ({where})",
                   edit={"nerves_stash_addr": "0x10000000", "ver": "U-Boot 1999.01"},
                   post=[("fdtcontroladdr", ""), ("nerves_disk", "")])
        yield dict(base, name=f"nerves_state=ok + empty key ({where})",
                   edit=dict(poison, nerves_state="ok"), post=[("", "x")], malformed=True)
        yield dict(base, name=f"short nerves_owned ({where})",
                   edit=dict(poison, nerves_owned="bootcmd", nerves_state="ok"))
        yield dict(base, name=f"partial: slot b, wdt, cmdline ({where})",
                   edit={"nerves_fw_active": "b", "nerves_fw_booted": "1",
                         "nerves_fw_validated": "1", "nerves_watchdog": "1",
                         "cmdline": "init=/bin/sh"},
                   post=[("", "x")], malformed=True)
        # Bindings that would make the restore fail: a type the compiled-in
        # value does not satisfy, and a callback that rejects it, left behind
        # by deleting .callbacks through a callback that does not unbind. The
        # rebuild drops the latter, so that block counts.
        yield dict(base, name=f".flags vetoes the restore ({where})", edit=poison,
                   post=[(".flags", "nerves_save:d,nerves_crumbs:d,nerves_go:d")], malformed=True)
        yield dict(base, name=f"orphaned callbacks on own vars ({where})", edit=poison,
                   post=[(".callbacks", "nerves_save:baudrate,nerves_crumbs:baudrate,"
                                        "nerves_go:baudrate,.callbacks:loadaddr"),
                         (".callbacks", "")])
        yield from binding_blocks(base, where)
    yield {"name": "stash moved, disk 0 (SD, both ours)", "sd": "ours", "emmc": "ours", "on": "sd",
           "edit": {"nerves_disk": "0", "nerves_stash_addr": "0x10000000"}}
    for where, sd, emmc in (("SD", "ours", "stock"), ("eMMC", None, "ours")):
        yield {"name": f"many userspace keys round-trip ({where})", "sd": sd, "emmc": emmc,
               "on": "sd" if sd else "emmc", "edit": userspace_keys(), "roundtrip": True}


# B booted once and never validated: the next boot must revert to A.
UNVALIDATED_B = {"nerves_fw_active": "b", "nerves_fw_booted": "1", "nerves_fw_validated": "0"}


def binding_blocks(base, where):
    """Blocks whose flag or callback bindings would pin a variable the script
    sets after the load. A binding still declared at the end of the block
    rejects it (`malformed`); one whose declaration the block deleted again
    must be gone, so the block counts and the A/B rule holds."""
    yield dict(base, name=f".flags pins nerves_fw_active ({where})", edit=UNVALIDATED_B,
               post=[(".flags", "nerves_fw_active:sr")], malformed=True)
    pinned = [
        ("nerves_fw_booted", dict(UNVALIDATED_B, nerves_fw_booted="0")),
        ("nerves_fw_validated", UNVALIDATED_B),
        ("nerves_slot", dict(UNVALIDATED_B, nerves_slot="b", nerves_part="4")),
        ("nerves_save_needed", dict(UNVALIDATED_B, nerves_fw_booted="0", nerves_save_needed="0")),
        ("bootargs", dict(UNVALIDATED_B, bootargs="root=/dev/mmcblk0p4 init=/bin/sh")),
    ]
    for var, edit in pinned:
        yield dict(base, name=f".flags pins {var} ({where})", edit=edit,
                   post=[(".flags", f"{var}:sr")], malformed=True)
    yield dict(base, name=f".callbacks pins nerves_fw_active ({where})", edit=UNVALIDATED_B,
               post=[(".callbacks", "nerves_fw_active:baudrate")], malformed=True)
    # .flags is rebound to a callback that ignores it, so deleting it leaves
    # the per-variable flags set; .callbacks then removes itself the same way.
    yield dict(base, name=f".flags deleted, pin left ({where})", edit=UNVALIDATED_B,
               post=[(".flags", "nerves_fw_active:sr,nerves_fw_validated:sr"),
                     (".callbacks", ".flags:loadaddr,.callbacks:loadaddr"),
                     (".flags", ""), (".callbacks", "")])
    yield dict(base, name=f".callbacks deleted, pin left ({where})", edit=UNVALIDATED_B,
               post=[(".callbacks", "nerves_fw_active:baudrate,nerves_fw_validated:baudrate,"
                                    ".callbacks:loadaddr"),
                     (".callbacks", "")])
    # U-Boot escapes newlines in values but not in names, so a text export
    # of this block would read back as nerves_fw_active=b.
    yield dict(base, name=f"newline in a name ({where})", edit={"x\nnerves_fw_active": "b"})
    yield from table_full_blocks(base, where)


# Every variable the script creates or sets after the state load, explicitly
# or as a command's side effect.
POST_LOAD = ("bootargs", "nerves_uboot_version", "nerves_args_rest", "filesize",
             "nerves_crumb_src", "nerves_crumb_size", "nerves_crumb_file", "fileaddr", "fdtaddr")
FILL = [(f"fill{i:03d}", "x") for i in range(600)]


def table_full_blocks(base, where):
    """A block can fill U-Boot's 521-entry hash table, so that creating a
    variable fails. Whatever it leaves out, the boot must go on with exactly
    this boot's command line and the A/B rule."""
    upgrade_b = {"nerves_fw_active": "b", "nerves_fw_booted": "0", "nerves_fw_validated": "0"}
    present = {k: "x" for k in POST_LOAD}
    yield dict(base, name=f"table full, upgrade->b ({where})", edit=dict(present, **upgrade_b),
               post=FILL, full=True)
    yield dict(base, name=f"table full, none set later ({where})", edit=upgrade_b,
               post=FILL, full=True)
    yield dict(base, name=f"table full, B unvalidated ({where})", edit=UNVALIDATED_B,
               post=FILL, full=True)
    for var in POST_LOAD:
        yield dict(base, name=f"table full, lacks {var} ({where})",
                   edit=dict({k: v for k, v in present.items() if k != var}, **upgrade_b),
                   post=FILL, full=True)
    # A block that deletes compiled-in variables fills their slots too; the
    # rebuild puts them back, so part of the snapshot no longer fits and the
    # block counts as absent.
    yield dict(base, name=f"table full, deletes bootargs ({where})", edit=UNVALIDATED_B,
               post=[("bootargs", ""), ("filesize", "")] + FILL, full=True, malformed=True)
    # More cmdline words than CONFIG_SYS_MAXARGS lets setenv take, then a
    # cmdline longer than setexpr's 16 KiB buffer: no command line, no boot.
    yield dict(base, name=f"cmdline over maxargs ({where})",
               edit={"cmdline": " ".join(f"w{i}" for i in range(60))}, args_fail="unset")
    yield dict(base, name=f"cmdline over 16 KiB ({where})",
               edit={"cmdline": " ".join("v" * 2000 for _ in range(9))}, args_fail=True)


def userspace_keys():
    """What a long-lived Nerves device accumulates. No backslashes: U-Boot's
    import takes them as escapes, so a raw one written by fwup or fw_setenv
    never survives."""
    keys = {f"nerves_fw_app{i}": f"value {i} with = and spaces" for i in range(150)}
    keys.update({"a.nerves_fw_uuid": "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
                 "b.nerves_fw_uuid": "6fa459ea-ee8a-3ca4-894e-db77e160355e",
                 "a.nerves_fw_validated": "1", "b.nerves_fw_validated": "0",
                 "nerves_serial_number": "GREEN-0001", "x-dash.dot": "1",
                 "multi": "line one\nline two", "UPPER": "#not a comment"})
    return keys


def upgrade(state, target):
    slot = target[0]
    for s in "ab":
        state.pop(f"{s}.nerves_fw_validated", None)
    state.update(nerves_fw_active=slot, nerves_fw_validated="0", nerves_fw_booted="0")
    if target.endswith("+auto"):
        state["nerves_fw_autovalidate"] = "1"
    return state


def make_memfile(path, size):
    with open(path, "wb") as f:
        f.truncate(size)
        f.seek(RAMOOPS[0])
        body = bytearray(random.Random(7).randbytes(RAMOOPS[1]))
        body[0x20000:0x20004] = (0x43474244).to_bytes(4, "little")
        f.write(body)
    return bytes(body)


def run_scenario(runner, fixture, sc):
    failures = []
    rows = []
    sd = make_disk(fixture, sc["sd"], "sd", runner.sd) if sc["sd"] else None
    if not sc["sd"] and os.path.exists(runner.sd):
        os.unlink(runner.sd)
    emmc = make_disk(fixture, sc["emmc"], "emmc", runner.emmc)
    edited = set()
    for name, d in (("sd", sd), ("emmc", emmc)):
        if d is None:
            continue
        st = d.state()
        if st is None:
            continue
        if sc.get("upgrade"):
            st = upgrade(st, sc["upgrade"])
        if sc.get("on", name) == name:
            st.update(sc.get("edit", {}))
            st = sc.get("pre", []) + list(st.items()) + sc.get("post", [])
            edited.add(name)
        d.set_state(st)
    absent = edited if sc.get("malformed") else set()
    original_keys = {}
    for name, d in (("sd", sd), ("emmc", emmc)):
        if d and d.state():
            # U-Boot cannot hold an empty value (`setenv x ""` deletes x), so
            # only non-empty keys must survive its save, as on any Nerves board.
            original_keys[name] = {k: v for k, v in d.state().items()
                                   if v and (sc.get("roundtrip") and k in sc["edit"]
                                             or k.startswith(("a.", "b.", "nerves_serial")))}
    memfile = None
    ram = None
    if sc.get("ramoops"):
        memfile = os.path.join(runner.args.work, "ram.bin")
    for boot in range(3):
        if memfile:
            ram = make_memfile(memfile, 512 << 20)
        sd_state = sd.state() if sd and "sd" not in absent else None
        emmc_state = emmc.state() if "emmc" not in absent else None
        exp = model(sc["sd"], sc["emmc"], sd_state, emmc_state, sc.get("spl"))
        before = {"sd": sd.hashes() if sd else None, "emmc": emmc.hashes()}
        out = runner.boot(sd is not None, sc.get("spl"), memfile)
        got = parse_boot(out)
        after = {"sd": sd.hashes() if sd else None, "emmc": emmc.hashes()}
        changed = {m: {r for r in after[m] if after[m][r] != before[m][r]}
                   for m in ("sd", "emmc") if after[m]}
        tag = f"{sc['name']} boot {boot + 1}"

        def check(cond, msg):
            if not cond:
                failures.append(f"{tag}: {msg}")

        check("@@TIMEOUT" not in out, "sandbox timed out")
        if sc.get("full") and boot == 0:
            # Later boots import U-Boot's own save of the full table, which
            # fills it exactly and so prints nothing.
            check("can't insert" in out, "the block did not fill the variable table")
        want_outcome = "boot" if exp["boots"] and not sc.get("args_fail") else "reset"
        check(got["outcome"] == want_outcome, f"outcome {got['outcome']}, want {want_outcome}")
        check(got.get("disk") == str(exp["disk"]), f"disk {got.get('disk')}, want {exp['disk']}")
        check(got.get("state") == exp["state"], f"state {got.get('state')}, want {exp['state']}")
        if got["outcome"] == "boot":
            part = 4 if exp["slot"] == "b" else 3
            check(got.get("slot") == exp["slot"], f"slot {got.get('slot')}, want {exp['slot']}")
            args = got.get("bootargs", "").split()
            roots = [a for a in args if a.startswith("root=")]
            check(roots == [f"root=/dev/mmcblk{exp['disk']}p{part}"], f"bootargs root: {got.get('bootargs')}")
            check(f"uboot.boot_disk=mmcblk{exp['disk']}" in args, "bootargs boot_disk")
            check(any(re.fullmatch(r"uboot\.version=U-Boot_2026\.04_[^ ()]+", a) for a in args),
                  "bootargs uboot.version")
            cons = [a for a in args if a.startswith("console=")]
            check(cons == ["console=ttyS2,1500000n8", "console=tty0"], f"consoles {cons}")
            want_args = [f"root=/dev/mmcblk{exp['disk']}p{part}", "rootfstype=squashfs", "rootwait",
                         "console=ttyS2,1500000n8", "console=tty0",
                         f"uboot.boot_disk=mmcblk{exp['disk']}", f"uboot.boot_disk_by={exp['by']}",
                         f"uboot.sd_fit={exp['sd_fit']}"] + exp["cmdline"]
            check([a for a in args if not a.startswith("uboot.version=")] == want_args,
                  f"bootargs {got.get('bootargs')}, want {' '.join(want_args)} + uboot.version")
            check(got.get("kernel") == f"IMAGE.{exp['slot']}@{exp['medium']}",
                  f"kernel {got.get('kernel')}")
            check(got.get("dtb") == f"DTB.{exp['slot']}@{exp['medium']}", f"dtb {got.get('dtb')}")
            wdt = got.get("wdt", [])
            want_wdt = [0x1, 0xFF, 0, 0x76] if exp["watchdog"] else [0, 0, 0, 0]
            check(wdt == want_wdt, f"watchdog registers {wdt}, want {want_wdt}")
        check(got.get("led") == ("on" if got["outcome"] == "boot" else "off"),
              f"user LED {got.get('led')}")
        for m, regions in changed.items():
            check(not regions & {"gpt", "loader", "fit", "p1rest", "rest"},
                  f"{m}: protected region changed: {sorted(regions)}")
            chosen = (m == "sd") == (exp["disk"] == 1)
            allowed = set()
            if chosen and exp["save"]:
                allowed.add("state")
            if chosen and m == "sd":
                allowed.add("fat")
            check(regions <= allowed, f"{m}: changed {sorted(regions)}, allowed {sorted(allowed)}")
            if chosen and exp["save"]:
                check("state" in regions, f"{m}: state not saved")
        disk = sd if exp["disk"] == 1 else emmc
        if exp["save"]:
            st = disk.state()
            check(st is not None, "saved block fails CRC (fw_printenv would reject it)")
            if st:
                for k, v in exp["new"].items():
                    check(st.get(k) == v, f"saved {k}={st.get(k)}, want {v}")
                for k, v in original_keys.get(exp["medium"], {}).items():
                    check(st.get(k) == v, f"saved block lost {k}")
        rows.append((tag, exp, got, changed))
        if sc.get("between") and sc["between"][boot] == "validate":
            # What nerves_runtime's validate does once the slot is healthy.
            st = disk.state()
            if st is not None:
                st.update({"nerves_fw_validated": "1", f"{exp['slot']}.nerves_fw_validated": "1"})
                disk.set_state(st)
    # Steady state: two boots in a row that save nothing write nothing at all.
    if len(rows) == 3 and not rows[1][1]["save"] and not rows[2][1]["save"]:
        for m, regions in rows[2][3].items():
            if regions:
                failures.append(f"{sc['name']} boot 3: steady-state boot wrote {m} {sorted(regions)}")
    files, outdir = runner.fat_files(sd is not None)
    sd_chosen = any(r[1]["disk"] == 1 for r in rows)
    if files["emmc"] & set(CRUMBS):
        failures.append(f"{sc['name']}: breadcrumbs on the eMMC FAT: {sorted(files['emmc'] & set(CRUMBS))}")
    if sd is not None and has_fat(sc["sd"]):
        crumbs = files["sd"] & set(CRUMBS)
        want = {"uboot-vars.txt", "uboot-fdt.dtb"} | ({"ramoops.bin"} if sc.get("ramoops") else set())
        if sd_chosen and crumbs != want:
            failures.append(f"{sc['name']}: SD breadcrumbs {sorted(crumbs)}, want {sorted(want)}")
        if not sd_chosen and crumbs:
            failures.append(f"{sc['name']}: breadcrumbs on an SD that was not booted")
        if sd_chosen:
            failures += check_crumbs(sc, outdir, rows[-1], ram)
    return rows, failures


def check_crumbs(sc, outdir, last, ram):
    failures = []
    path = os.path.join(outdir, "uboot-vars.txt")
    try:
        text = open(path).read()
    except OSError:
        return [f"{sc['name']}: uboot-vars.txt not readable"]
    if "\0" in text:
        failures.append(f"{sc['name']}: uboot-vars.txt is not plain text")
    v = dict(l.split("=", 1) for l in text.splitlines() if "=" in l)
    want = [("nerves_disk", "1"), ("nerves_disk_by", last[1]["by"]),
            ("nerves_sd_fit", last[1]["sd_fit"])]
    if last[1]["spl"] is not None:
        want.append(("nerves_spl_boot_device", last[1]["spl"]))
    for k, value in want + [
                    ("nerves_slot", last[1]["slot"]), ("nerves_state", last[1]["state"])]:
        if v.get(k) != value:
            failures.append(f"{sc['name']}: uboot-vars.txt {k}={v.get(k)}, want {value}")
    # What the last boot handed to booti, or the placeholder nothing boots with.
    want_args = last[2].get("bootargs") if last[2]["outcome"] == "boot" else None
    if sc.get("args_fail") == "unset":
        want_args = "unset"
    if want_args is not None and v.get("bootargs") != want_args:
        failures.append(f"{sc['name']}: uboot-vars.txt bootargs={v.get('bootargs')}, want {want_args}")
    if not v.get("ver", "").startswith("U-Boot 2026.04"):
        failures.append(f"{sc['name']}: uboot-vars.txt ver={v.get('ver')}")
    try:
        with open(os.path.join(outdir, "uboot-fdt.dtb"), "rb") as f:
            if f.read(4) != bytes.fromhex("d00dfeed"):
                failures.append(f"{sc['name']}: uboot-fdt.dtb is not a dtb")
        if ram is not None:
            with open(os.path.join(outdir, "ramoops.bin"), "rb") as f:
                if f.read() != ram:
                    failures.append(f"{sc['name']}: ramoops.bin differs from the RAM region")
    except OSError as e:
        failures.append(f"{sc['name']}: breadcrumb not readable: {e}")
    return failures


def owned_check(env_path):
    """Every compiled-in key except the Nerves state must be reset after an
    import, or a stale export could replace it."""
    text = re.sub(r"\\\n\s*", " ", open(env_path).read())
    keys = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z0-9_]+)=(.*)$", line)
        if m:
            keys[m.group(1)] = m.group(2)
    state = set(DEFAULTS) | {"cmdline"}
    owned = set(keys.get("nerves_owned", "").split())
    missing = set(keys) - owned - state
    out = [f"uboot.env: {k} is not in nerves_owned" for k in sorted(missing)]
    # What the disk choice sets before the import must be in both snapshots
    # (the copy and the re-export compared with it), or a block could change it.
    picked = set(re.findall(r"setenv (\w+)", keys.get("nerves_pick_disk", "")))
    if not picked:
        out.append("uboot.env: nerves_pick_disk sets nothing (the script changed shape)")
    exports = re.findall(r"env export -t -s 0x10000 0x[0-9a-f]+ ([^;&]*)", keys.get("nerves_load_state", ""))
    if len(exports) != 2:
        out.append(f"uboot.env: nerves_load_state has {len(exports)} snapshot exports, want 2")
    for names in exports:
        words = names.replace("${nerves_owned}", " ".join(owned)).split()
        listed = set(words)
        out += [f"uboot.env: {k}, set by nerves_pick_disk, is not in a snapshot"
                for k in sorted(picked - listed)]
        # `env export -t -s <size> <addr>` plus the names, against the
        # Green's (and the sandbox's) CONFIG_SYS_MAXARGS.
        if 6 + len(words) > 64:
            out.append(f"uboot.env: a snapshot export has {6 + len(words)} arguments, over 64")
    # Past the import a block may have filled the table, so every variable a
    # later step sets must exist already: compiled in, and owned unless it is
    # Nerves state. nerves_load_state's own `setenv nerves_state ok` follows
    # the check that the snapshot, nerves_state included, was put back.
    setters = r"(?:setenv|env set|setexpr|fdt header get|fdt get (?:value|addr|size|name))"
    for k, v in keys.items():
        if k in ("nerves_pick_disk", "nerves_load_state", "nerves_owned"):
            continue
        targets = set(re.findall(setters + r" (\S+)", v))
        if re.search(r"\b(?:load|fatload|env export) ", v):
            targets.add("filesize")
        out += [f"uboot.env: {k} sets {t}, which is not compiled in and owned"
                for t in sorted(targets - (set(keys) & (owned | state)))]
    return out


def main():
    p = argparse.ArgumentParser()
    for a in ("uboot", "mkenvimage", "dtc", "src", "build", "env", "repo", "work"):
        p.add_argument("--" + a, required=True)
    p.add_argument("--only", help="run only the scenarios whose name matches this regex")
    args = p.parse_args()
    shutil.rmtree(args.work, ignore_errors=True)
    os.makedirs(args.work)
    fixture = Fixture(args)
    runner = Runner(args, fixture)
    all_failures = owned_check(args.env)
    print(f"{'scenario':<44} {'boot':>4}  {'disk':>4} {'state':<5} {'slot':<4} {'saved':<5} result")
    for sc in scenarios():
        if args.only and not re.search(args.only, sc["name"]):
            continue
        rows, failures = run_scenario(runner, fixture, sc)
        for tag, exp, got, changed in rows:
            n = tag.rsplit(" ", 1)[1]
            mine = [f for f in failures if f.startswith(f"{tag}:")]
            saved = "yes" if any("state" in r for r in changed.values()) else "-"
            print(f"{sc['name']:<44} {n:>4}  {got.get('disk', '?'):>4} {got.get('state', '?'):<5} "
                  f"{(got.get('slot') or got['outcome']):<4} {saved:<5} {'FAIL' if mine else 'ok'}")
        all_failures += failures
    if all_failures:
        print(f"\n{len(all_failures)} failure(s):")
        for f in all_failures:
            print("  " + f)
        sys.exit(1)
    print("\nall scenarios passed")


if __name__ == "__main__":
    main()
