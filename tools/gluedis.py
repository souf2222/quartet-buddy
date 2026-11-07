#!/usr/bin/env python3
"""gluedis.py — tiny Mach-O (arm64) section + capstone explorer for the stripped
ApogeeGlue binary. Input: /tmp/glue_arm64 (make with `lipo -thin arm64 <bin> -o /tmp/glue_arm64`).

  sections                list sections
  strings <needle>        strings (all data sections) with VAs
  xref <VA>               adrp+add pairs computing address == VA (with context)
  disasm <VA> [n]         disasm n instructions at VA (default 80)
  func <VA>               dump the containing function (unwind-derived start)
  stub <VA-of-stub>       resolve a __stubs entry to its import symbol
"""
import re, struct, sys, os

BIN = os.environ.get("GLUE_BIN", "/tmp/glue_arm64")
data = open(BIN, "rb").read()
import capstone as cs
md = cs.Cs(cs.CS_ARCH_ARM64, cs.CS_MODE_LITTLE_ENDIAN)
md.detail = False

cmdsize_total = struct.unpack_from("<I", data, 0x14)[0]
SECTIONS, SYMOFF, NSYMS, STROFF, IND_OFF, IND_N, STUBS, GOT = {}, 0, 0, 0, 0, 0, None, None
pos = 0x20
while pos < 0x20 + cmdsize_total:
    cmd, csize = struct.unpack_from("<II", data, pos)
    if cmd == 0x19:  # LC_SEGMENT_64
        name = data[pos+8:pos+24].rstrip(b"\0").decode(errors="replace")
        nsects = struct.unpack_from("<I", data, pos+68)[0]
        for i in range(nsects):
            off = pos + 72 + i*80
            sname  = data[off:off+16].rstrip(b"\0").decode(errors="replace")
            sseg   = data[off+16:off+32].rstrip(b"\0").decode(errors="replace")
            addr, size, fo = struct.unpack_from("<QQIIII", data, off+32)[:3]
            SECTIONS[f"{sseg},{sname}"] = dict(addr=addr, size=size, off=fo, seg=sseg, sect=sname)
    elif cmd == 0x2:   # LC_SYMTAB
        SYMOFF, NSYMS, STROFF, SSTRSIZE = struct.unpack_from("<IIII", data, pos+8)
    elif cmd == 0xB:   # LC_DYSYMTAB
        vals = struct.unpack_from("<18I", data, pos+8)
        IND_OFF = vals[16-4]  # indirectsymoff is the 15th of 18 fields? we index below
        IND_OFF = vals[15]
        IND_N   = vals[16]
    elif cmd == 0x80000022 and data[pos+8:pos+12].rstrip(b"\0").decode(errors="replace") != "" :
        import os as _o
    pos += csize
# __stubs / __got lookup at runtime
def sect(name):
    return SECTIONS.get(name)

def read_va(va, n):
    for s in SECTIONS.values():
        if s["addr"] <= va < s["addr"] + s["size"]:
            d = va - s["addr"]
            return data[s["off"]+d : s["off"]+d+n]
    return b"\0"*n

def cstr(va, maxlen=300):
    b = read_va(va, maxlen)
    z = b.find(b"\0")
    return b[:z if z >= 0 else maxlen].decode("utf-8", "replace")

def symname(idx):
    e = data[SYMOFF + idx*16 : SYMOFF + (idx+1)*16]
    n_strx = struct.unpack_from("<I", e, 0)[0]
    s = data[STROFF + n_strx : STROFF + n_strx + 300]
    return s[:s.find(b"\0")].decode("utf-8", "replace")

def unresolved(idx):
    e = data[SYMOFF + idx*16: SYMOFF + (idx+1)*16]
    typ = e[4]
    return (typ & 0x0E) != 0  # N_TYPE in {U,TOC,SECT,UNDF,ABS}? classic check

def do_strings(needle):
    for key, s in SECTIONS.items():
        if s["seg"] == "__LINKEDIT": continue
        blob = data[s["off"] : s["off"] + s["size"]]
        for m in re.finditer(re.escape(needle.encode()), blob):
            va = s["addr"] + m.start()
            end = blob.find(b"\0", m.start())
            limit = min(end if 0 <= end <= s["size"] else s["size"], m.start() + 200)
            snippet = blob[m.start():limit].decode("utf-8", "replace")
            print(f"{va:x}  [{key}]  {snippet[:160]}")

def unwind_starts():
    s = sect("__TEXT,__unwind_info")
    b = data[s["off"] : s["off"] + s["size"]]
    first_level = struct.unpack_from("<I", b, 4)[0]
    n_pages = struct.unpack_from("<I", b, 8)[0]
    starts = set()
    for p in range(n_pages):
        second = struct.unpack_from("<I", b, first_level + p*8 + 4)[0]
        if not second: continue
        kind, cnt, enc = struct.unpack_from("<IBB", b, second)
        # kind 2 = compressed 2-level, kind 3 = regular/old (IPP)
        p2 = second
        if kind == 2:
            second_level_off = struct.unpack_from("<I", b, second + 4)[0]
            array_cnt = struct.unpack_from("<I", b, second + 8)[0]
            # skip to second level page array
            page_off = second + second_level_off + array_cnt*4
            idx = struct.unpack_from("<I", b, second + array_cnt*4 + second_level_off + (va_page_hint:=0) if False else 0)
        else:
            n_regular = struct.unpack_from("<I", b, second + 8)[0]
            for i in range(n_regular):
                entry = struct.unpack_from("<I", b, second + 8*4 + i*4)[0]
                if entry: starts.add(entry & ~3)
    return sorted(starts)

def func_start(va):
    starts = unwind_starts()
    lo = 0
    for x in starts:
        if x <= va: lo = x
    return lo

def do_dis(va, n):
    code = read_va(va, n*4)
    for ins in md.disasm(code, va):
        print(f"{ins.address:x}: {ins.mnemonic} {ins.op_str}")

def stub_resolve(va):
    s = sect("__TEXT,__stubs")
    if not s or not (s["addr"] <= va < s["addr"]+s["size"]):
        print("not a stub"); return
    code = read_va(va, 16)
    for ins in md.disasm(code, va):
        if "ldr" in ins.mnemonic:
            m = re.search(r"#(0x[0-9a-f]+)", ins.op_str)
            if m:
                got_va = (ins.address & ~0xFFF) + int(m.group(1), 16)
                for g, gs in SECTIONS.items():
                    if gs["addr"] <= got_va < gs["addr"]+gs["size"]:
                        rel = got_va - gs["addr"]
                        slot = rel // 8
                        idx = struct.unpack_from("<I", data, IND_OFF + (gs and 0)*4)[0]
                        break
    print("(indirect mapping fallback — see stub <va>)")

def dump_func(va):
    st = func_start(va)
    nxt = [x for x in unwind_starts() if x > st]
    end = nxt[0] if nxt else va + 4000
    n = min((end - st)//4, 6000)
    print(f"function ≈[{st:x} … {end:x})  ({n} ins)")
    do_dis(st, n)

def do_xref(va):
    txt = sect("__TEXT,__text")
    code = data[txt["off"]: txt["off"]+txt["size"]]
    ins_list = list(md.disasm(code, txt["addr"]))
    regbase, started_at = {}, None
    for i, ins in enumerate(ins_list):
        if ins.mnemonic == "adrp":
            m = re.match(r"(x\d+|w\d+), #(0x?[0-9a-f]+)", ins.op_str)
            if m:
                regbase[m.group(1)] = (ins.address & ~0xFFF) + int(m.group(2), 0) if False else ins.address & ~0xFFF
                # capstone op_str for adrp gives '#0x...' — page-relative not including pc base? Actually differs; fall back:
                regbase[m.group(1)] = (ins.address & ~0xFFF)
        elif ins.mnemonic in ("add", "ldr") and len(ins.op_str.split(",")) >= 2:
            m = re.match(r"(x\d+|w\d+), (x\d+|w\d+)", ins.op_str)
            if m:
                src = m.group(2)
                if src in regbase:
                    mm = re.search(r"#(0x[0-9a-f]+|\d+)", ins.op_str)
                    full = regbase[src] + (int(mm.group(1), 0) if mm else 0)
                    if full == va:
                        print(f"adrp+add at {ins.address:x} -> {full:x}")
                        for a, mn, ops in ins_list[max(0,i-14):i+12]:
                            print(f"   {a:x}: {mn} {ops}")
                        print("────────")

usage = __doc__

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "sections":
        for k, s in SECTIONS.items():
            print(f"{s['addr']:x}-{s['addr']+s['size']:x} [{k}] off={s['off']}")
    elif cmd == "strings": do_strings(sys.argv[2])
    elif cmd == "xref": do_xref(int(sys.argv[2], 0))
    elif cmd == "disasm": do_dis(int(sys.argv[2], 0), int(sys.argv[3], 0) if len(sys.argv) > 3 else 80)
    elif cmd == "func": dump_func(int(sys.argv[2], 0))
    elif cmd == "starts":
        ss = unwind_starts()
        print(len(ss), "start candidates; first 5:", [hex(x) for x in ss[:5]], "last:", [hex(x) for x in ss[-3:]])
    else: print(usage)

if __name__ == "__main__":
    main()
