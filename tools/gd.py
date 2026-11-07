#!/usr/bin/env python3
"""gd.py — minimal, verified Mach-O arm64 explorer for the stripped ApogeeGlue.

  python3 tools/gd.py sections
  python3 tools/gd.py strings <needle>
  python3 tools/gd.py xref <VA>              # adrp+add/ldr pairs == VA (+context)
  python3 tools/gd.py dis <VA> [n] [start]   # disasm; annotate BL/BLR with stub names
  python3 tools/gd.py f <VA>                 # whole function via __unwind_info starts
"""
import struct, sys, os, subprocess, re

BIN = os.environ.get("GLUE_BIN", "/tmp/glue_arm64")
import capstone as cs
md = cs.Cs(cs.CS_ARCH_ARM64, cs.CS_MODE_LITTLE_ENDIAN)

class MachO:
    def __init__(self, path=BIN):
        self.data = open(path, "rb").read()
        # Build section list from `otool -l` (stable authoritative text format)
        self.sections = {}
        out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
        seg = None
        sect_name = sect_seg = None
        sect_addr = sect_size = sect_off = None
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("segname "):
                seg = s.split()[1]
            elif s.startswith("sectname "):
                sect_name = s.split()[1]
            elif s.startswith("addr ") and sect_name:
                sect_addr = int(s.split()[1], 16)
            elif s.startswith("size ") and sect_name:
                sect_size = int(s.split()[1], 16)
            elif s.startswith("offset ") and sect_name and sect_addr is not None:
                sect_off = int(s.split()[1])
                key = f"{seg},{sect_name}"
                self.sections[key] = dict(addr=sect_addr, size=sect_size, off=sect_off)
                sect_addr = None

    def sect(self, key): return self.sections.get(key)

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
        out = []
        for key, s in self.sections.items():
            if key.startswith("__LINKEDIT"): continue
            blob = self.data[s["off"]: s["off"]+s["size"]]
            for m in re.finditer(re.escape(needle.encode()), blob):
                va = s["addr"] + m.start()
                e = blob.find(b"\0", m.start())
                snippet = blob[m.start(): e if e >= 0 else m.start()+140].decode("utf-8","replace")
                out.append((va, key, snippet))
        return out

    # ---- stub symbol map via otool -Iv (reliable) ----
    def stub_map(self):
        mp = {}
        out = subprocess.run(["otool", "-Iv", BIN], capture_output=True, text=True).stdout
        cur = None
        for line in out.splitlines():
            if "Indirect symbols for" in line:
                cur = re.search(r"for \(([^)]+)\)", line).group(1)
            m = re.match(r"0x([0-9a-f]+)\s+(\d+)\s+(\S+)", line)
            if m and cur:
                mp[int(m.group(1), 16)] = m.group(3)
        return mp

    def sym(self, idx):
        e = self.data[self.indsym_off + idx*4 : self.indsym_off + (idx+1)*4]
        if not e: return None
        v = struct.unpack("<I", e)[0]
        if v == 0xFFFFFFFF: return None
        d = self.data  # symtab via -Iv is easier; fall back through symtab
        # symtab walk
        pos, SYMOFF, NSYMS, STROFF = 0x20, 0, 0, 0
        ncmds, sizeof = struct.unpack_from("<II", d, 0x10)
        while pos + 8 <= 0x20 + sizeof:
            cmd, csize = struct.unpack_from("<II", d, pos)
            if cmd == 0x2:
                SYMOFF, NSYMS, STROFF, _ = struct.unpack_from("<IIII", d, pos+8)
            pos += csize
        ent = d[SYMOFF+v*16 : SYMOFF+(v+1)*16]
        n_strx = struct.unpack_from("<I", ent, 0)[0]
        s = d[STROFF+n_strx:]
        return s[:s.find(b"\0")].decode("utf-8", "replace")

M = MachO()
SMAP = M.stub_map()
TEXT = M.sect("__TEXT,__text")

def dis(va, n, annotate=True):
    code = M.read_va(va, n*4)
    out = []
    for ins in md.disasm(code, va):
        ann = ""
        m = re.match(r"(?:bl|b|blr)\s+#?0x([0-9a-f]+)", ins.mnemonic + " " + ins.op_str)
        if ins.mnemonic in ("bl", "b"):
            tm = re.search(r"(0x[0-9a-f]+)$", ins.op_str)
            if tm:
                tgt = int(tm.group(1), 16)
                if tgt in SMAP: ann = f" → {SMAP[tgt]}"
                else:
                    a = M.cstr(tgt, 60)
                    if a and len(a) > 3 and a.isprintable(): ann = f" → \"{a[:40]}\""
        out.append(f"{ins.address:x}: {ins.mnemonic}\t{ins.op_str}{ann}")
    return out

def unwind_starts():
    s = M.sect("__TEXT,__unwind_info")
    b = M.read_va(s["addr"], s["size"])
    first_level = struct.unpack_from("<I", b, 4)[0]
    n_pages = struct.unpack_from("<I", b, 8)[0]
    common_encodings_off = struct.unpack_from("<I", b, 4*3)[0]
    personalities_off = struct.unpack_from("<I", b, 4*4)[0]
    index_section_off = struct.unpack_from("<I", b, 4*5)[0]
    index_section_count = struct.unpack_from("<I", b, 4*6)[0]
    starts = set()
    for i in range(max(n_pages, index_section_count) - 1):
        # format hint from Apple libunwind: index has uint32 functionOffset then info
        pass
    # second-level: parse known format: __unwind_info layout
    #   firstLevel: uint32 begin(uint32 end pairs) — we read pairs of (functionOffset infoOffset=secondlevel)
    for p in range(n_pages - 1):
        second = struct.unpack_from("<I", b, first_level + p*8 + 4)[0]
        if not second: continue
        kind, cnt, enc = struct.unpack_from("<IBB", b, second)
        if kind == 2:
            page2_off = second
            pages = struct.unpack_from("<I", b, page2_off + 4)[0]
            entry_cnt = struct.unpack_from("<I", b, page2_off+8)[0]
            # see Apple: second_level_page { next/mock; compact/unwind entries }
            base = page2_off
            pages_arr_off = base + pages
            entries_off = page2_off - 0 if False else 0
            # layout per apple: page: uint32 next; uint32 ipOffsetsStart? assumption: skip — sample: many tools parse kind 2 as: at +4 pages(dict) via 'u32 page_offs[cnt]'
            arr = [struct.unpack_from("<I", b, pages_arr_off + 4*i)[0] for i in range(entry_cnt)]
            for a in arr:
                starts.add(a)
        elif kind == 3:  # regular
            nreg = struct.unpack_from("<I", b, second + 8)[0]
            for i in range(nreg):
                e = struct.unpack_from("<I", b, second + 8 + 8 + i*4)[0]
                if e: starts.add(e & ~0x3)
    return sorted(starts)

def func_start(va):
    try: return max(x for x in unwind_starts() if x <= va if x)
    except Exception: return max(0x1000030c0, va - 3000)

def func_end(va):
    st = func_start(va)
    try: return min(x for x in unwind_starts() if x > st) or st + 4000
    except Exception: return st + 4000

def do_func(va):
    st, e = func_start(va), func_end(va)
    n = min((e - st)//4, 6000)
    print(f"function ≈ [{st:x} … {e:x})  ({n} ins)")
    print("\n".join(dis(st, n)))

def do_xref(va):
    winner = M.read_va(TEXT["addr"], TEXT["size"])
    ins_list = list(md.disasm(winner, TEXT["addr"]))
    regbase = {}
    for i, ins in enumerate(ins_list):
        mm = re.match(r"(x\d+|w\d+), #(0x[0-9a-f]+)", ins.op_str)
        if ins.mnemonic == "adrp" and mm:
            regbase[mm.group(1)] = int(mm.group(2), 16)
        elif ins.mnemonic in ("add", "ldr"):
            rm = re.match(r"(x\d+|w\d+), (x\d+|w\d+)(?:, )?", ins.op_str)
            if rm:
                src = rm.group(2)
                if src in regbase:
                    om = re.search(r"#(0x[0-9a-f]+)", ins.op_str)
                    full = regbase[src] + (int(om.group(1), 16) if om else 0)
                    if full == va:
                        print(f"== xref at {ins.address:x}")
                        for line in dis(ins.address - 15*4, 28):
                            print("   ", line)
                        print("────────")

def main():
    a = sys.argv
    if len(a) < 2:
        print(__doc__); return
    if a[1] == "sections":
        for k, v in sorted(M.sections.items(), key=lambda kv: kv[1]["addr"]):
            print(f"{v['addr']:x}-{v['addr']+v['size']:x} [{k}] off={v['off']}")
    elif a[1] == "strings":
        for va, k, s in M.strings(a[2]):
            print(f"{va:x} [{k}] {s[:120]}")
    elif a[1] == "xref":
        do_xref(int(a[2], 0))
    elif a[1] == "dis":
        n = int(a[3], 0) if len(a) > 3 else 80
        st = func_start(int(a[2], 0)) if len(a) > 4 and a[4] == "func" else int(a[2], 0)
        print("\n".join(dis(st, n)))
    elif a[1] == "f":   # function dump
        do_func(int(a[2], 0))
    elif a[1] == "starts":
        ss = unwind_starts()
        print(len(ss), "starts →", [hex(x) for x in ss[:3]], "…", [hex(x) for x in ss[-2:]])
    else:
        print(__doc__)

if __name__ == "__main__":
    main()
