"""Builds a small FIT from a contract file, optionally broken on purpose.

Only for scripts/test-guards.sh: the guards must be shown to fail, and a real
u-boot.itb cannot be bent into each violation.
Usage: fit_fabricate.py <contract> <out.itb> [mutation]
"""

import hashlib
import struct
import sys

MARKER = b"bootcmd=run nerves_main; run nerves_fail\0"


def cells(v):
    return struct.pack(">I", v)


def strs(*s):
    return b"".join(x.encode() + b"\0" for x in s)


def build_fdt(root):
    strtab, offs = bytearray(), {}

    def name_off(n):
        if n not in offs:
            offs[n] = len(strtab)
            strtab.extend(n.encode() + b"\0")
        return offs[n]

    out = bytearray()

    def emit(name, node):
        out.extend(struct.pack(">I", 1))
        out.extend(name.encode() + b"\0")
        out.extend(b"\0" * (-len(out) % 4))
        for k, v in node["props"]:
            out.extend(struct.pack(">III", 3, len(v), name_off(k)))
            out.extend(v)
            out.extend(b"\0" * (-len(v) % 4))
        for cname, c in node["children"]:
            emit(cname, c)
        out.extend(struct.pack(">I", 2))

    emit("", root)
    out.extend(struct.pack(">I", 9))
    off_struct = 40 + 16
    off_str = off_struct + len(out)
    total = off_str + len(strtab)
    hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_str, 40, 17, 16, 0, len(strtab), len(out))
    return hdr + b"\0" * 16 + bytes(out) + bytes(strtab)


def parse_contract(path):
    default, configs, images = None, {}, {}
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        kind, rest = ln.split(" ", 1)
        if kind == "default":
            default = rest
            continue
        name, *kv = rest.split()
        props = dict(x.split("=", 1) for x in kv)
        (configs if kind == "config" else images)[name] = props
    return default, configs, images


def main(argv):
    contract, out_path = argv[0], argv[1]
    mut = argv[2] if len(argv) > 2 else None
    default, configs, images = parse_contract(contract)

    if mut == "drop-node":
        images.pop("atf-6")
        configs["config-1"]["loadables"] = configs["config-1"]["loadables"].replace(",atf-6", "")
    if mut == "default-missing":
        default = "nope"

    if mut == "dangling-ref":
        images.pop("atf-6")
    if mut == "extra-image":
        images["atf-7"] = dict(images["atf-6"])

    datas, img_nodes = [], []
    pos = prev_pos = 0
    for name, p in sorted(images.items()):
        data = bytes(64)
        if name == "u-boot":
            data = MARKER if mut != "no-env" else b"bootcmd=bootflow scan\0"
            data = data.ljust(64, b"\0")
        if mut == "oversize" and name == "u-boot":
            data = data.ljust(9 << 20, b"\0")
        props = [("description", strs(name)), ("type", strs(p["type"]))]
        if p["arch"] != "-":
            props.append(("arch", strs(p["arch"])))
        if p["os"] != "-":
            props.append(("os", strs(p["os"])))
        comp = "gzip" if mut == "gzip" and name == "u-boot" else "none"
        if not (mut == "no-compression" and name == "u-boot"):
            props.append(("compression", strs(comp)))
        for k in ("load", "entry"):
            if p[k] != "-":
                v = int(p[k], 16)
                if mut == "load" and name == "u-boot" and k == "load":
                    v += 0x1000
                props.append((k, cells(v)))
        off = pos
        if mut == "overlap" and name == "atf-3":
            off = prev_pos + 16
        first = name == "atf-1"
        if not (mut in ("no-size", "no-payload") and first):
            props.append(("data-size", cells(0 if mut == "zero-size" and first else len(data))))
        if mut == "into-header" and name == "atf-2":
            props.append(("data-position", cells(8)))
        elif not (mut in ("no-offset", "no-payload") and first):
            props.append(("data-offset", cells(off)))
        if mut == "both-offsets" and first:
            props.append(("data-position", cells(0x1000)))
        if mut == "embedded" and first:
            props = [kv for kv in props if not kv[0].startswith("data-")]
            props.append(("data", data))
        hval = hashlib.sha256(data).digest()
        hprops = [("algo", strs("md5" if mut == "md5" and name == "atf-1" else "sha256")), ("value", hval)]
        if mut == "no-hash-value" and name == "atf-1":
            hprops = hprops[:1]
        if mut == "short-hash-value" and name == "atf-1":
            hprops[1] = ("value", hval[:16])
        hashnode = {"props": hprops, "children": []}
        children = [] if mut == "nohash" and name == "atf-2" else [("hash", hashnode)]
        img_nodes.append((name, {"props": props, "children": children}))
        datas.append(data)
        prev_pos = pos
        pos += (len(data) + 3) & ~3

    conf_nodes = []
    for name, p in configs.items():
        fw = p["firmware"] if mut != "firmware" else "atf-2"
        conf_nodes.append((name, {"props": [
            ("description", strs(name)), ("firmware", strs(fw)),
            ("loadables", strs(*p["loadables"].split(","))), ("fdt", strs(p["fdt"]))], "children": []}))

    root = {"props": [("description", strs("fabricated")), ("#address-cells", cells(1))],
            "children": [("images", {"props": [], "children": img_nodes}),
                         ("configurations", {"props": [("default", strs(default))], "children": conf_nodes})]}
    blob = build_fdt(root)
    blob += b"\0" * (-len(blob) % 4)
    body = b"".join(((d + b"\0" * (-len(d) % 4)) for d in datas))
    if mut == "truncated":
        body = body[:-32]
    if mut == "bad-hash":
        body = bytes([body[0] ^ 1]) + body[1:]
    with open(out_path, "wb") as f:
        f.write(blob + body)


if __name__ == "__main__":
    main(sys.argv[1:])
