#!/usr/bin/env python3
"""Read nodes out of a device tree blob with no dtc on the host.

    tools/dtb-dump.py <blob.dtb> <regex>          # nodes whose path or compatible matches
    tools/dtb-dump.py <blob.dtb> --phandle 0x3c   # resolve a phandle to its node

Cell properties are printed as words in hex; string lists as text. Phandle words
inside `*-gpios`, `*-supply`, `mboxes` and `interrupts-extended` are resolved to
the node they name, because that is the part a driver needs and the part that is
easy to misread as a number. Written for the mondrian port (`dtb/mondrian-live.dtb`),
where the phone's own tree is the only source for an address.
"""
import re
import struct
import sys

BEGIN_NODE, END_NODE, PROP, END = 1, 2, 3, 9
CELL_KEYS = ("gpio", "supply", "mbox", "interrupt", "clock", "wrapper", "phandle")


def load(path):
    data = open(path, "rb").read()
    if struct.unpack(">I", data[:4])[0] != 0xD00DFEED:
        sys.exit("%s is not a device tree blob" % path)
    (magic, total, off_struct, off_strings, off_rsv, version, last_comp,
     boot_cpu, size_strings, size_struct) = struct.unpack(">10I", data[:40])
    strings = data[off_strings:off_strings + size_strings]
    pos = off_struct
    stack = []
    nodes = {}
    while pos < off_struct + size_struct:
        token = struct.unpack(">I", data[pos:pos + 4])[0]
        pos += 4
        if token == BEGIN_NODE:
            raw = data[pos:data.index(b"\x00", pos) + 1]
            pos += (len(raw) + 3) & ~3
            stack.append(raw.split(b"\x00", 1)[0].decode("ascii", "replace"))
        elif token == END_NODE:
            stack.pop()
        elif token == PROP:
            length, nameoff = struct.unpack(">II", data[pos:pos + 8])
            pos += 8
            value = data[pos:pos + length]
            pos += (length + 3) & ~3
            end = strings.index(b"\x00", nameoff)
            nodes.setdefault("/".join(stack) or "/", {})[
                strings[nameoff:end].decode()] = value
        elif token == END:
            break
    phandles = {}
    for path, props in nodes.items():
        for k in ("phandle", "linux,phandle"):
            if k in props and len(props[k]) == 4:
                phandles[struct.unpack(">I", props[k])[0]] = path
    return nodes, phandles


def cells_for(key, phandles, nodes):
    """How many cells follow a phandle in this property, from the target node."""
    if key.endswith("-names") or key.endswith("names"):
        return None
    if "supply" in key:
        return 0
    if "gpio" in key:
        want = "#gpio-cells"
    elif "clock" in key:
        want = "#clock-cells"
    elif "mbox" in key:
        want = "#mbox-cells"
    elif "interrupt" in key:
        want = "#interrupt-cells"
    else:
        return None
    return want


def show(key, value, phandles, nodes):
    want = cells_for(key, phandles, nodes)
    if want is None and value and all(32 <= b < 127 or b == 0 for b in value):
        return " ".join(p.decode() for p in value.split(b"\x00") if p)
    if len(value) % 4:
        return value.hex()
    words = list(struct.unpack(">%dI" % (len(value) // 4), value))
    if want is not None and want in (0, "#gpio-cells", "#clock-cells", "#mbox-cells"):
        out = []
        i = 0
        while i < len(words):
            target = phandles.get(words[i])
            if target is None:
                out.append(str(words[i]))
                i += 1
                continue
            n = 0 if want == 0 else struct.unpack(
                ">I", nodes[target].get(want, b"\x00\x00\x00\x00"))[0]
            out.append("<%s%s>" % (target, "".join(
                " %#x" % w for w in words[i + 1:i + 1 + n])))
            i += 1 + n
        return " ".join(out)
    out = []
    for w in words:
        out.append(str(w) if w < (1 << 24) else "0x%x" % w)
    return " ".join(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    nodes, phandles = load(sys.argv[1])
    if sys.argv[2] == "--phandle":
        for arg in sys.argv[3:]:
            n = int(arg, 0)
            print("0x%x -> %s" % (n, phandles.get(n, "?")))
        return
    rx = re.compile(sys.argv[2], re.I)
    for path in sorted(nodes):
        props = nodes[path]
        compat = props.get("compatible", b"").decode("ascii", "replace")
        if not (rx.search(path) or rx.search(compat.replace("\x00", " "))):
            continue
        print("\n%s" % (path or "/"))
        for k in sorted(props):
            if k in ("phandle", "linux,phandle"):
                continue
            print("    %-26s %s" % (k, show(k, props[k], phandles, nodes)))


if __name__ == "__main__":
    main()
