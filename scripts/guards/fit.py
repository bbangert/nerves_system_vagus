"""Checks a U-Boot FIT (u-boot.itb) against what the board's stock SPLs load.

The FIT is a flattened device tree with external data, parsed here with the
stdlib so no dtc is needed at build time. Why each rule exists: the stock SPL
only decompresses gzip (and only if built with it), silently jumps into
garbage on any other compression, rejects unknown hash algorithms, and
rejects an image whose payload does not hash to the recorded sha256.
"""

import hashlib
import re
import struct
import sys

WINDOW_BYTES = 16384 * 512
ENV_MARKER = b"bootcmd=run nerves_main"


class FitError(Exception):
    pass


class Node:
    def __init__(self, name):
        self.name, self.props, self.children = name, {}, []

    def child(self, name):
        return next((c for c in self.children if c.name == name), None)

    def strings(self, key):
        raw = self.props.get(key)
        if raw is None:
            return None
        return [s.decode() for s in raw.split(b"\0") if s] if raw.endswith(b"\0") else None

    def string(self, key):
        s = self.strings(key)
        return s[0] if s else None

    def cell(self, key):
        raw = self.props.get(key)
        if raw is None:
            return None
        if len(raw) not in (4, 8):
            raise FitError("%s/%s is %d bytes, not a 32/64-bit cell" % (self.name, key, len(raw)))
        return int.from_bytes(raw, "big")


def parse_fdt(b):
    if len(b) < 40:
        raise FitError("too short for an FDT header")
    magic, total, off_struct, off_str, _, _, _, _, size_str, size_struct = struct.unpack_from(">10I", b, 0)
    if magic != 0xD00DFEED:
        raise FitError("not an FDT (magic %#x)" % magic)
    if total > len(b) or off_struct + size_struct > total or off_str + size_str > total:
        raise FitError("FDT header points outside the file")
    strings = b[off_str:off_str + size_str]
    pos, stack, root = off_struct, [], None
    end = off_struct + size_struct
    while pos + 4 <= end:
        tok = struct.unpack_from(">I", b, pos)[0]
        pos += 4
        if tok == 1:
            nul = b.index(b"\0", pos)
            node = Node(b[pos:nul].decode())
            pos = (nul + 4) & ~3
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            stack.append(node)
        elif tok == 2:
            stack.pop()
        elif tok == 3:
            ln, nameoff = struct.unpack_from(">II", b, pos)
            pos += 8
            nul = strings.index(b"\0", nameoff)
            stack[-1].props[strings[nameoff:nul].decode()] = bytes(b[pos:pos + ln])
            pos = (pos + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            break
        else:
            raise FitError("bad FDT token %#x at %d" % (tok, pos - 4))
    if root is None or stack:
        raise FitError("unbalanced FDT structure")
    return root, total


def hexval(v):
    return "-" if v is None else "0x%08x" % v


def images_of(root):
    imgs = root.child("images")
    if imgs is None:
        raise FitError("no /images node")
    return imgs.children


def contract_lines(root):
    lines = []
    confs = root.child("configurations")
    if confs is None:
        raise FitError("no /configurations node")
    lines.append("default %s" % confs.string("default"))
    for c in sorted(confs.children, key=lambda n: n.name):
        lines.append("config %s firmware=%s loadables=%s fdt=%s" % (
            c.name,
            ",".join(c.strings("firmware") or ["-"]),
            ",".join(c.strings("loadables") or ["-"]),
            ",".join(c.strings("fdt") or ["-"])))
    for i in sorted(images_of(root), key=lambda n: n.name):
        lines.append("image %s type=%s os=%s arch=%s load=%s entry=%s" % (
            i.name, i.string("type") or "-", i.string("os") or "-", i.string("arch") or "-",
            hexval(i.cell("load")), hexval(i.cell("entry"))))
    return lines


def read_contract(path):
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]


def payloads(root, hdr_total, errs):
    base = (hdr_total + 3) & ~3
    out = []
    for i in images_of(root):
        # Embedded data would share the SPL's 1 MiB malloc pool with the FIT
        # header; the stock FIT is external throughout.
        if "data" in i.props:
            errs.append("image %s: embedded data property; payloads must be external (data-size + data-offset)" % i.name)
            continue
        size, off, pos = i.cell("data-size"), i.cell("data-offset"), i.cell("data-position")
        if size is None:
            errs.append("image %s: no data-size, so no payload" % i.name)
        elif size == 0:
            errs.append("image %s: data-size is 0, empty payload" % i.name)
        if off is None and pos is None:
            errs.append("image %s: neither data-offset nor data-position, no payload location" % i.name)
        elif off is not None and pos is not None:
            errs.append("image %s: both data-offset and data-position (ambiguous)" % i.name)
        if not size or (off is None) == (pos is None):
            continue
        start = base + off if off is not None else pos
        if start < base:
            errs.append("image %s: payload starts at byte %d, inside the FDT header (ends at %d)" % (i.name, start, base))
            continue
        out.append((i.name, start, start + size))
    return out


def check_payloads(root, hdr_total, data, errs):
    spans = payloads(root, hdr_total, errs)
    for name, start, end in spans:
        if end > len(data):
            errs.append("image %s: payload %d-%d extends past the end of the file (%d bytes)" % (name, start, end, len(data)))
    for n, (a, s0, e0) in enumerate(spans):
        for b, s1, e1 in spans[n + 1:]:
            if s0 < e1 and s1 < e0:
                errs.append("images %s and %s: payloads overlap (%d-%d and %d-%d)" % (a, b, s0, e0, s1, e1))
    by_name = {i.name: i for i in images_of(root)}
    for name, start, end in spans:
        if end > len(data):
            continue
        digest = hashlib.sha256(data[start:end]).digest()
        for h in by_name[name].children:
            if not h.name.startswith("hash") or h.string("algo") != "sha256":
                continue
            value = h.props.get("value")
            if value is None or len(value) != 32:
                errs.append("image %s: %s has no 32-byte value (the SPL checks it)" % (name, h.name))
            elif value != digest:
                errs.append("image %s: %s value does not match the sha256 of its payload (the SPL would reject the FIT)" % (name, h.name))
    return max([hdr_total] + [e for _, _, e in spans])


def check_references(root, dconf, errs):
    present = {i.name for i in images_of(root)}
    named = set()
    for key in ("firmware", "loadables", "fdt"):
        for n in dconf.strings(key) or []:
            named.add(n)
            if n not in present:
                errs.append("default configuration %s: %s names image %s, which is not under /images" % (dconf.name, key, n))
    for n in sorted(present - named):
        errs.append("image %s: not referenced by default configuration %s" % (n, dconf.name))


def kconfig(text):
    vals = {}
    for ln in text.splitlines():
        m = re.match(r"^CONFIG_(\w+)=(.*)$", ln)
        if m:
            vals[m.group(1)] = m.group(2).strip('"')
    return vals


def check_config(path, errs):
    with open(path) as f:
        cfg = kconfig(f.read())
    for k in ("SPL_FIT_SIGNATURE", "SPL_SHA256", "ENV_IS_NOWHERE"):
        if cfg.get(k) != "y":
            errs.append("%s: CONFIG_%s must be y, is %s" % (path, k, cfg.get(k, "unset")))
    for k in ("SPL_GZIP", "SPL_LZMA", "ENV_REDUNDANT", "CMD_SF"):
        if k in cfg:
            errs.append("%s: CONFIG_%s must not be set, is %s" % (path, k, cfg[k]))
    size = cfg.get("ENV_SIZE")
    if size is None or int(size, 0) != 0x20000:
        errs.append("%s: CONFIG_ENV_SIZE must be 0x20000, is %s" % (path, size or "unset"))


def check(itb_path, contract_path, config_path):
    errs = []
    with open(itb_path, "rb") as f:
        data = f.read()
    root, total = parse_fdt(data)

    confs = root.child("configurations")
    default = confs.string("default") if confs else None
    dconf = confs.child(default) if default else None
    if dconf is None:
        errs.append("no default configuration naming an existing config (default = %r)" % default)
    elif (dconf.strings("firmware") or [None])[0] != "atf-1":
        errs.append("default configuration %s: firmware is %r, must be atf-1" % (default, dconf.strings("firmware")))

    for i in images_of(root):
        comp = i.string("compression")
        if comp != "none":
            errs.append("image %s: compression is %r, must be \"none\" (the stock SPL cannot unpack anything else)" % (i.name, comp))
        hashes = [h for h in i.children if h.name.startswith("hash")]
        if not hashes:
            errs.append("image %s: no hash node (must be sha256)" % i.name)
        for h in hashes:
            if h.string("algo") != "sha256":
                errs.append("image %s: %s algo is %r, must be sha256" % (i.name, h.name, h.string("algo")))

    ext = check_payloads(root, total, data, errs)
    if dconf is not None:
        check_references(root, dconf, errs)
    if ext > len(data):
        errs.append("external data ends at byte %d but the file is %d bytes (truncated)" % (ext, len(data)))
    if max(ext, len(data)) > WINDOW_BYTES:
        errs.append("FIT is %d bytes, over the 8 MiB window at LBA 16384-32767" % max(ext, len(data)))

    want, have = read_contract(contract_path), contract_lines(root)
    for ln in want:
        if ln not in have:
            errs.append("contract line missing or different: %s" % ln)
    for ln in have:
        if ln not in want:
            errs.append("not in the contract: %s" % ln)

    if ENV_MARKER not in data:
        errs.append("%r not found: the boot script is not compiled in and U-Boot would run its stock bootflow scan" % ENV_MARKER.decode())

    if config_path:
        check_config(config_path, errs)
    return errs


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "--print-contract":
            with open(argv[1], "rb") as f:
                print("\n".join(contract_lines(parse_fdt(f.read())[0])))
            return 0
        config = None
        if "--config" in argv:
            i = argv.index("--config")
            config = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]
        if len(argv) != 2:
            print("usage: check-fit.sh [--config <u-boot .config>] <u-boot.itb> <contract file>\n"
                  "       check-fit.sh --print-contract <u-boot.itb>", file=sys.stderr)
            return 2
        errs = check(argv[0], argv[1], config)
    except (FitError, OSError, ValueError, IndexError) as e:
        errs = ["%s" % e]
    if errs:
        for e in errs:
            print("check-fit: FAIL %s" % e, file=sys.stderr)
        return 1
    print("check-fit: OK %s" % argv[0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
