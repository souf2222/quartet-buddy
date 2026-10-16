#!/usr/bin/env python3
"""Broader brute-force of the VTS path-id hash (target: hwout0.gain = 0xB5BDA2C5)."""
import zlib, itertools

TARGETS = {0xB5BDA2C5: "fader(hwout0.gain)"}

def crc32(s): return zlib.crc32(s.encode()) & 0xFFFFFFFF
def crc32_be32(s): return zlib.crc32(s.encode())
def fnv1a(s):
    h = 0x811C9DC5
    for c in s.encode(): h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h
def fnv1(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = (h * 0x01000193) & 0xFFFFFFFF
        h ^= c
    return h
def djb2(s):
    h = 5381
    for c in s.encode(): h = (h * 33 + c) & 0xFFFFFFFF
    return h
def djb2x(s):
    h = 5381
    for c in s.encode(): h = ((h * 33) ^ c) & 0xFFFFFFFF
    return h
def java31(s):
    h = 0
    for c in s.encode(): h = (h * 31 + c) & 0xFFFFFFFF
    return h
def juce31(s):
    h = 0
    for c in s:
        h = (h * 31 + ord(c)) & 0xFFFFFFFF
    return h
def sdbm(s):
    h = 0
    for c in s.encode(): h = (c + (h << 6) + (h << 16) - h) & 0xFFFFFFFF
    return h
def elf(s):
    h = 0
    for c in s.encode():
        h = (h << 4) + c
        g = h & 0xF0000000
        if g: h ^= g >> 24
        h &= (~g) & 0xFFFFFFFF
    return h
def bkdr131(s):
    h = 0
    for c in s.encode(): h = (h * 131 + c) & 0xFFFFFFFF
    return h
def dek(s):
    h = len(s)
    for c in s.encode(): h = ((h << 5) ^ (h >> 27) ^ c) & 0xFFFFFFFF
    return h
def ap(s):
    h = 0xAAAAAAAA
    for i, c in enumerate(s.encode()):
        h ^= c if (i & 1) == 0 else (h << 5) ^ (h >> 2) ^ c
        h &= 0xFFFFFFFF
    return h

HASHES = {"crc32": crc32, "fnv1a": fnv1a, "fnv1": fnv1, "djb2": djb2, "djb2x": djb2x,
          "java31": java31, "juce31": juce31, "sdbm": sdbm, "elf": elf,
          "bkdr131": bkdr131, "dek": dek, "ap": ap}

SER = "quartet1528B15CEE547FA"
def candidates():
    seps = ["/", ".", ":", "", "|"]
    bases = []
    for sep in seps:
        bases += [
            f"{SER}",
            f"dev{sep}{SER}",
            f"root{sep}dev{sep}{SER}",
            f"/root{sep}dev{sep}{SER}",
        ]
    mids = []
    for sep in seps:
        mids += [f"hwout{sep}hwout0", "hwout0"]
    props = [".gain", ":gain", "/gain", "|gain", " gain"]
    for b in bases:
        for sep in seps:
            for m in mids:
                for p in props:
                    yield f"{b}{sep}{m}{p}"
    # name-based
    for b in bases:
        for sep in seps:
            for nm in ["Main Out", "hwout.hwout0.Main Out"]:
                for p in [".gain", ":gain", "/gain"]:
                    yield f"{b}{sep}{nm}{p}"

seen = set()
for s in candidates():
    if s in seen:
        continue
    seen.add(s)
    for hname, hfn in HASHES.items():
        try:
            v = hfn(s)
        except Exception:
            continue
        if v in TARGETS:
            print(f"MATCH path='{s}' hash={hname} -> {hex(v)}")
print(f"tried {len(seen)} paths x {len(HASHES)} hashes")
