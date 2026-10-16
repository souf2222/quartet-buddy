#!/usr/bin/env python3
"""JUCE ValueTree binary stream + var parser (per juce_ValueTree.cpp / juce_Variant.cpp)."""

class Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def byte(self):
        b = self.d[self.p]
        self.p += 1
        return b

    def read(self, n):
        v = self.d[self.p:self.p + n]
        self.p += n
        return v

    def int32(self):
        return int.from_bytes(self.read(4), "little", signed=True)

    def int64(self):
        return int.from_bytes(self.read(8), "little", signed=True)

    def double(self):
        import struct
        return struct.unpack("<d", self.read(8))[0]

    def cint(self):
        """JUCE readCompressedInt: byte0 = (count | 0x80*negative); then count bytes little-endian magnitude."""
        b = self.byte()
        n = b & 0x7F
        v = int.from_bytes(self.read(n), "little") if n else 0
        return -v if (b & 0x80) else v

    def string(self):
        """readString: UTF-8 bytes until NUL."""
        out = bytearray()
        while True:
            b = self.byte()
            if b == 0:
                break
            out.append(b)
        return out.decode("utf-8", "replace")

    def var(self):
        n = self.cint()
        if n <= 0:
            return None
        tag = self.byte()
        if tag == 1:   # int
            return self.int32()
        if tag == 6:   # int64
            return self.int64()
        if tag == 2:
            return True
        if tag == 3:
            return False
        if tag == 4:   # double
            return self.double()
        if tag == 5:   # string (n = len+2, includes tag byte + NUL)
            return self.read(n - 1).rstrip(b"\x00").decode("utf-8", "replace")
        if tag == 8:   # binary
            return self.read(n - 1)
        if tag == 7:   # array
            count = self.cint()
            return [self.var() for _ in range(count)]
        if tag == 9:   # undefined
            return "undefined"
        self.p += n - 1
        return f"<tag {tag}>"

    def tree(self):
        t = self.string()
        if not t:
            return None
        node = {"type": t, "props": {}, "children": []}
        nprops = self.cint()
        for _ in range(nprops):
            name = self.string()
            node["props"][name] = self.var()
        nch = self.cint()
        for _ in range(nch):
            c = self.tree()
            if c is None:
                break
            node["children"].append(c)
        return node

    def tree_skip_var_int(self):
        """Some Apogee streams precede the tree with a compressed int."""
        pass

def dump(node, indent=0):
    if node is None:
        print(" " * indent + "<invalid>")
        return
    pad = " " * indent
    props = " ".join(f'{k}="{v}"' if not isinstance(v, bytes) else f'{k}=<{len(v)} bytes>'
                     for k, v in node["props"].items())
    print(f"{pad}<{node['type']} {props}>")
    for c in node["children"]:
        dump(c, indent + 2)

def to_xml(node, indent=0):
    pad = "  " * indent
    props = ""
    for k, v in node["props"].items():
        if isinstance(v, str):
            props += f' {k}="{v}"'
        elif isinstance(v, bool):
            props += f' {k}="{int(v)}"'
        elif isinstance(v, bytes):
            props += f' {k}="<binary {len(v)}>"'
        else:
            props += f' {k}="{v}"'
    if not node["children"]:
        return f"{pad}<{node['type']}{props}/>"
    inner = "\n".join(to_xml(c, indent + 1) for c in node["children"])
    return f"{pad}<{node['type']}{props}>\n{inner}\n{pad}</{node['type']}>"
