#!/usr/bin/env python3
"""Brute-force the Apogee ValueTreeSyncProtocol descriptor hash.

Known pairs (from capture: user moved Main Out fader, toggled mute, talkback):
  04 c5 a2 bd b5  -> double property, likely dev..hwout.hwout0.gain
  03 5f a9 c0 b5  -> bool
  03 8f 0a 6a 00  -> bool
  03 82 2c 69 37  -> bool
"""
import zlib, binascii

TARGETS = {
    "fader?":  [0xB5BDA2C5, 0xC5A2BDB5, 0xBDA2C504, 0x04C5A2BD],
    "bool1":   [0xB5C0A95F, 0x5FC0A9B5, 0x03B5C0A9],
    "bool2":   [0x006A0A8F, 0x8F0A6A00, 0x038F0A6A],
    "bool3":   [0x37692C82, 0x822C6937, 0x0337692C],
}

def crc32(s): return zlib.crc32(s.encode()) & 0xFFFFFFFF
def crc32_le(s): return zlib.crc32(s.encode()[::-1].encode()) & 0xFFFFFFFF
def fnv1a(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h
def fnv1(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = (h * 0x01000193) & 0xFFFFFFFF
        h ^= c
    return h
def djb2(s):
    h = 5381
    for c in s.encode():
        h = (h * 33 + c) & 0xFFFFFFFF
    return h
def djb2xor(s):
    h = 5381
    for c in s.encode():
        h = ((h * 33) ^ c) & 0xFFFFFFFF
    return h
def java31(s):
    h = 0
    for c in s.encode():
        h = (h * 31 + c) & 0xFFFFFFFF
    return h
def sdbm(s):
    h = 0
    for c in s.encode():
        h = (c + (h << 6) + (h << 16) - h) & 0xFFFFFFFF
    return h
def juce_string_hash(s):
    # JUCE String::hashCode: hash = 31*hash + char (over juce_wchar = UTF-32 codepoints)
    h = 0
    for c in s:
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
        if h >= 0x80000000:
            h -= 0x100000000  # signed 32-bit
    return h & 0xFFFFFFFF
def elf(s):
    h = 0
    for c in s.encode():
        h = (h << 4) + c
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
        h &= ~g & 0xFFFFFFFF
    return h & 0xFFFFFFFF
def bkdr(s):
    h = 0
    for c in s.encode():
        h = (h * 131 + c) & 0xFFFFFFFF
    return h

HASHES = {"crc32": crc32, "fnv1a": fnv1a, "fnv1": fnv1, "djb2": djb2,
          "djb2xor": djb2xor, "java31": java31, "sdbm": sdbm,
          "juce31": juce_string_hash, "elf": elf, "bkdr": bkdr}

SERIAL = "quartet1528B15CEE547FA"
def paths():
    bases = [
        f"{SERIAL}", f"dev.{SERIAL}", f"root.dev.{SERIAL}",
        f"/root/dev/{SERIAL}", f"root/dev/{SERIAL}",
    ]
    mids = ["hwout.hwout0", "hwout/hwout0", "hwout0", "hwout.hwout0.index0"]
    props = ["gain", "mute", "dim", "sum"]
    seps = [".", "/", ":"]
    out = []
    for b in bases:
        for s in seps:
            for m in mids:
                for p in props:
                    out.append(f"{b}{s}{m}{s}{p}")
                    out.append(f"{b}{s}{m}.{p}")
    # shorter candidates
    for m in mids + ["Main Out", "hwout.hwout1"]:
        for p in props:
            for s in seps:
                out.append(f"{m}{s}{p}")
    return out

all_targets = {}
for k, lst in TARGETS.items():
    for t in lst:
        all_targets.setdefault(t, []).append(k)

found = []
for s in paths():
    for hname, hfn in HASHES.items():
        v = hfn(s)
        if v in all_targets:
            found.append((s, hname, hex(v), all_targets[v]))
for f in found:
    print(f"MATCH: path='{f[0]}' hash={f[1]} value={f[2]} target={f[3]}")
if not found:
    print("no matches yet")
