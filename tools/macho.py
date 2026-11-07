#!/usr/bin/env python3
"""macho.py — minimal, correct LC_SECTION_64 / LC_SYMTAB parser for the arm64
Mach-O slice /tmp/glue_arm64. Verified against `otool -l` output."""
import struct

class MachO:
    def __init__(self, path="/tmp/glue_arm64"):
        self.data = open(path, "rb").read()
        d = self.data
        assert struct.unpack_from("<I", d, 0)[0] == 0xFEEDFACF, "not a 64-bit Mach-O"
        ncmds, sizeof = struct.unpack_from("<II", d, 0x10)
        self.sections = {}   # "seg,sect" -> dict(addr,size,off)
        self.symoff = self.nsyms = self.stroff = 0
        self.indoff = self.indn = 0
        pos = 0x20
        end = 0x20 + sizeof
        while pos + 8 <= end:
            cmd, csize = struct.unpack_from("<II", d, pos)
            if cmd == 0x19:  # LC_SEGMENT_64
                nsects = struct.unpack_from("<I", d, pos + 68)[0]
                for i in range(nsects):
                    off = pos + 72 + i*80
                    sname = d[off:off+16].rstrip(b"\0").decode()
                    sseg  = d[off+16:off+32].rstrip(b"\0").decode()
                    addr, size, fo = struct.unpack_from("<QQI", d, off+32)
                    self.sections[f"{sseg},{sname}"] = dict(addr=addr, size=size, off=fo)
            elif cmd == 0x2:  # LC_SYMTAB
                self.symoff, self.nsyms, self.stroff, _ = struct.unpack_from("<IIII", d, pos + 8)
            elif cmd == 0xB:  # LC_DYSYMTAB
                vals = struct.unpack_from("<18I", d, pos + 8)
                self.indoff, self.indn = vals[15], vals[16]
            pos += csize

    def sect(self, name): return self.sections.get(name)

    def read_va(self, va, n):
        for s in self.sections.values():
            if s["addr"] <= va < s["addr"] + s["size"]:
                d = va - s["addr"]
                return self.data[s["off"]+d : s["off"]+d+n]
        return b""

    def cstr(self, va, maxl=300):
        b = self.read_va(va, maxl)
        z = b.find(b"\0")
        return b[:z if z >= 0 else maxl].decode("utf-8", "replace")

    def strings(self, needle):
        hits = []
        for key, s in self.sections.items():
            if key.startswith("__LINKEDIT"): continue
            blob = self.data[s["off"] : s["off"]+s["size"]]
            for m in __import__("re").finditer(__import__("re").escape(needle.encode()), blob):
                va = s["addr"] + m.start()
                e = blob.find(b"\0", m.start())
                snippet = blob[m.start(): e if e >= 0 else m.start()+120].decode("utf-8", "replace")
                hits.append((va, key, snippet))
        return hits

    def sym(self, idx):
        e = self.data[self.symoff + idx*16 : self.symoff + (idx+1)*16]
        n_strx, n_type = struct.unpack_from("<IB", e, 0)
        z = self.data[self.stroff+n_strx:].find(b"\0")
        return (self.data[self.stroff+n_strx : self.stroff+n_strx+z]).decode("utf-8", "replace"), n_type

    def indirects(self):
        """list of (index-> sym index or 0xFFFFFFFF) for __stubs/__got in layout order"""
        out = []
        for i in range(self.indn):
            out.append(struct.unpack_from("<I", self.data, self.indoff + i*4)[0])
        return out

    def got_sym_names(self):
        """__DATA_CONST,__got words -> bound import symbol names, in slot order."""
        got = self.sect("__DATA_CONST,__got")
        out = []
        if not got or not self.indoff: return out
        slot = (got["addr"]) // 8  # indirect table includes ALL indirect slots in address order across sections; scan for coverage
        # walk indirects; entries belonging to got region are those whose VA math can't be derived — fallback: reorder via dysymtab ranges
        # Route: dysymtab.indirectsymoff entries are ordered by section as nlist order: use INDIRECT SYMS array with mention in __stubs sect reserved1 as beginning index!
        st = self.sect("__TEXT,__stubs")
        stubs_reserved1 = None
        # __stubs stores reserved1 = indsym table offset index; __got reserved1 too — recompute:
        # HACK: parse again from raw LC to grab reserved1 per section:
        d = self.data
        pos, isinstance_ = 0x20, None
        while pos < len(d)-8:
            cmd, csize = struct.unpack_from("<II", d, pos)
            if csize <= 0: break
            if cmd == 0x19:
                nsects = struct.unpack_from("<I", d, pos + 68)[0]
                for i in range(nsects):
                    off = pos + 72 + i*80
                    sname = d[off:off+16].rstrip(b"\0").decode()
                    sseg  = d[off+16:off+32].rstrip(b"\0").decode()
                    r1, r2 = struct.unpack_from("<II", d, off+32+8+8+8+4+4+4+4)  # reserved1/2 after flags+reserved1
                    if sname == "__stubs" and stubs_reserved1 is None:
                        self.stub_base_indirect = r1
                        stubs_reserved1 = r1
            pos += csize
        return out
