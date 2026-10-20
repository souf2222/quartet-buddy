#!/usr/bin/env python3
"""Crack the Apogee VTS path-id hash, using ALL known (path, id) pairs.

Validation set (captured live on two units — see docs/protocol-notes.md):
unit A = quartet1528B15CEE547FA, unit B = quartet15819153CE0E077.
A formula must reproduce EVERY pair (both endiannesses considered).
"""
import zlib, hashlib, struct, itertools

A = "quartet1528B15CEE547FA"
B = "quartet15819153CE0E077"

# (serial, node path components, prop, id bytes as on the wire)
PAIRS = [
    (A, ["hwout", "hwout0"], "gain", "c5a2bdb5"),
    (A, ["hwout", "hwout1"], "gain", "647b72b7"),
    (A, ["hwout", "hwout0"], "mute", "5fa9c0b5"),
    (A, ["hwout", "hwout1"], "mute", "fe8175b7"),
    (A, ["hwout", "hwout0"], "dim", "822c6937"),
    (A, ["hwin", "hwin0"], "analogRefLevel", "07511d73"),
    (A, ["hwin", "hwin0", "micSettings", "PreModelQuartet"], "gain", "f1e02cb3"),
    (A, ["hwin", "hwin0", "instSettings", "PreModelQuartet"], "gain", "863e271c"),
    (A, ["hwin", "hwin0", "micSettings"], "phantom", "02f86060"),
    (A, ["hwin", "hwin0"], "softLimit", "ab206ea4"),
    (A, ["hwin", "hwin0"], "polarityInvert", "ec6d2150"),
    (A, ["hwin", "hwin1"], "analogRefLevel", "e62eaf54"),
    (A, ["hwin", "hwin1", "micSettings", "PreModelQuartet"], "gain", "10a54cf0"),
    (A, ["hwin", "hwin1", "instSettings", "PreModelQuartet"], "gain", "47feff82"),
    (A, ["hwin", "hwin1", "micSettings"], "phantom", "83edf96c"),
    (A, ["hwin", "hwin1"], "softLimit", "6cd35239"),
    (A, ["hwin", "hwin1"], "polarityInvert", "cb4bb331"),
    (B, ["hwout", "hwout0"], "gain", "1f1d4c1d"),
    (B, ["hwout", "hwout1"], "gain", "bef5001f"),
    (B, ["hwout", "hwout0"], "mute", "b9234f1d"),
    (B, ["hwout", "hwout1"], "mute", "58fc031f"),
    (B, ["hwout", "hwout0"], "dim", "e8fe548d"),
]

# ---------------- hash functions (32-bit) ----------------
def h_crc32(s): return zlib.crc32(s) & 0xFFFFFFFF
def h_adler32(s): return zlib.adler32(s) & 0xFFFFFFFF
def h_fnv1a(s):
    h = 0x811C9DC5
    for c in s: h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h
def h_fnv1(s):
    h = 0x811C9DC5
    for c in s:
        h = (h * 0x01000193) & 0xFFFFFFFF
        h ^= c
    return h
def h_djb2(s):
    h = 5381
    for c in s: h = (h * 33 + c) & 0xFFFFFFFF
    return h
def h_djb2x(s):
    h = 5381
    for c in s: h = ((h * 33) ^ c) & 0xFFFFFFFF
    return h
def h_sdbm(s):
    h = 0
    for c in s: h = (c + (h << 6) + (h << 16) - h) & 0xFFFFFFFF
    return h
def h_java31(s):
    h = 0
    for c in s: h = (h * 31 + c) & 0xFFFFFFFF
    return h
def h_java31_utf32(s):
    h = 0
    for ch in s.decode("utf-8"): h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return h
def h_bkdr131(s):
    h = 0
    for c in s: h = (h * 131 + c) & 0xFFFFFFFF
    return h
def h_elf(s):
    h = 0
    for c in s:
        h = (h << 4) + c
        g = h & 0xF0000000
        if g: h ^= g >> 24
        h &= (~g) & 0xFFFFFFFF
    return h
def h_dek(s):
    h = len(s)
    for c in s: h = ((h << 5) ^ (h >> 27) ^ c) & 0xFFFFFFFF
    return h
def h_jenkins(s):
    h = 0
    for c in s:
        h = (h + c) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
def h_juce64_lo(s):
    h = 0
    for ch in s.decode("utf-8"): h = (h * 31 + ord(ch)) & 0xFFFFFFFFFFFFFFFF
    return h & 0xFFFFFFFF
def h_juce64_hi(s):
    h = 0
    for ch in s.decode("utf-8"): h = (h * 31 + ord(ch)) & 0xFFFFFFFFFFFFFFFF
    return (h >> 32) & 0xFFFFFFFF
def h_murmur3(s, seed=0):
    data = s
    length = len(data)
    nblocks = length // 4
    h = seed
    c1 = 0xCC9E2D51
    c2 = 0x1B873593
    for i in range(nblocks):
        k = struct.unpack("<I", data[i*4:i*4+4])[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
    k = 0
    tail = data[nblocks*4:]
    if len(tail) >= 3: k ^= tail[2] << 16
    if len(tail) >= 2: k ^= tail[1] << 8
    if len(tail) >= 1:
        k ^= tail[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= length
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF
    h ^= h >> 16
    return h
def h_murmur3_s1(s): return h_murmur3(s, 1)
def h_murmur3_juce(s): return h_murmur3(s, 0x9747B28C)
def h_xxh32(s, seed=0):
    data = s
    length = len(data)
    P1, P2, P3, P4, P5 = 2654435761, 2246822519, 3266489917, 668265263, 374761393
    def rotl(x, r): return ((x << r) | (x >> (32 - r))) & 0xFFFFFFFF
    def round_(acc, val):
        acc = (acc + val * P2) & 0xFFFFFFFF
        acc = rotl(acc, 13)
        acc = (acc * P1) & 0xFFFFFFFF
        return acc
    n = length // 16
    if n == 0:
        h = (seed + P5) & 0xFFFFFFFF
    else:
        v1 = (seed + P1 + P2) & 0xFFFFFFFF
        v2 = (seed + P2) & 0xFFFFFFFF
        v3 = seed
        v4 = (seed - P1) & 0xFFFFFFFF
        for i in range(n):
            v1 = round_(v1, struct.unpack("<I", data[i*16:i*16+4])[0])
            v2 = round_(v2, struct.unpack("<I", data[i*16+4:i*16+8])[0])
            v3 = round_(v3, struct.unpack("<I", data[i*16+8:i*16+12])[0])
            v4 = round_(v4, struct.unpack("<I", data[i*16+12:i*16+16])[0])
        h = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & 0xFFFFFFFF
    h = (h + length) & 0xFFFFFFFF
    i = n * 16
    while i + 4 <= length:
        h = (h + struct.unpack("<I", data[i:i+4])[0] * P3) & 0xFFFFFFFF
        h = (rotl(h, 17) * P4) & 0xFFFFFFFF
        i += 4
    while i < length:
        h = (h + data[i] * P5) & 0xFFFFFFFF
        h = (rotl(h, 11) * P1) & 0xFFFFFFFF
        i += 1
    h ^= h >> 15
    h = (h * P2) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * P3) & 0xFFFFFFFF
    h ^= h >> 16
    return h
def _digest_slices(name):
    def mk(idx, endian):
        def f(s):
            d = hashlib.new(name, s).digest()
            return int.from_bytes(d[idx:idx+4], endian)
        return f
    return mk
HASHES = {
    "crc32": h_crc32, "adler32": h_adler32, "fnv1a": h_fnv1a, "fnv1": h_fnv1,
    "djb2": h_djb2, "djb2x": h_djb2x, "sdbm": h_sdbm, "java31": h_java31,
    "java31u32": h_java31_utf32, "bkdr131": h_bkdr131, "elf": h_elf, "dek": h_dek,
    "jenkins": h_jenkins, "juce64lo": h_juce64_lo, "juce64hi": h_juce64_hi,
    "murmur3_0": h_murmur3, "murmur3_1": h_murmur3_s1, "murmur3_juce": h_murmur3_juce,
    "xxh32_0": h_xxh32,
    "md5[0:4]le": _digest_slices("md5")(0, "little"), "md5[0:4]be": _digest_slices("md5")(0, "big"),
    "md5[-4:]le": _digest_slices("md5")(12, "little"), "md5[-4:]be": _digest_slices("md5")(12, "big"),
    "sha1[0:4]le": _digest_slices("sha1")(0, "little"), "sha1[0:4]be": _digest_slices("sha1")(0, "big"),
    "sha1[-4:]le": _digest_slices("sha1")(16, "little"), "sha1[-4:]be": _digest_slices("sha1")(16, "big"),
    "sha256[0:4]le": _digest_slices("sha256")(0, "little"), "sha256[0:4]be": _digest_slices("sha256")(0, "big"),
    "sha256[-4:]le": _digest_slices("sha256")(28, "little"), "sha256[-4:]be": _digest_slices("sha256")(28, "big"),
}

# ---------------- path string templates ----------------
def templates(serial, comps, prop):
    """yield candidate full path strings"""
    # component list variants: with/without container nodes
    comp_variants = [
        comps,                                   # hwout/hwout0/...
        [c for c in comps if not c.startswith("hw") or c in ("hwin", "hwout")],  # drop container
    ]
    # actually build explicit variants
    comp_variants = [comps]
    if len(comps) >= 2:
        comp_variants.append(comps[1:])          # drop hwout/hwin container
    prefixes = [
        [], ["root"], ["dev"], ["root", "dev"], ["dev", "root"],
        [serial] + ["dev"], ["dev", serial], ["root", serial], ["root", "dev", serial],
    ]
    seps = ["/", ".", ":", ""]
    prop_joins = [".", "/", ":", "", "@", "$", "::"]
    for cv in comp_variants:
        for pre in prefixes:
            parts = pre + cv
            for sep in seps:
                body = sep.join(parts)
                if not body:
                    continue
                for pj in prop_joins:
                    yield body + pj + prop
                    yield body + sep + prop
    # leading-slash variants
    for cv in comp_variants:
        for pre in prefixes:
            parts = pre + cv
            for sep in seps:
                body = sep.join(parts)
                if not body:
                    continue
                for pj in prop_joins:
                    yield "/" + body + pj + prop
    # bare / name-based
    yield ".".join(comps) + "." + prop
    yield "/".join(comps) + "/" + prop

def encodings(s):
    b = s.encode("utf-8")
    yield b
    yield b + b"\x00"

def main():
    # precompute targets
    targets = {}   # int -> (pair idx, endianness)
    for i, (ser, comps, prop, idhex) in enumerate(PAIRS):
        raw = bytes.fromhex(idhex)
        le = int.from_bytes(raw, "little")
        be = int.from_bytes(raw, "big")
        targets.setdefault(le, []).append((i, "le"))
        targets.setdefault(be, []).append((i, "be"))

    # First: find candidate (template-signature, hashfn) hits on pair 0, then validate all.
    # Strategy: for each hash fn and each template VARIETY on pair 0, record;
    # the same variety must then reproduce every other pair.
    first = PAIRS[0]
    hits = []
    tested = 0
    # We canonicalize the template by regenerating the same variant index for each pair.
    # Simpler: enumerate (prefix-idx, sep-idx, propjoin-idx, variant-idx, leading-slash) explicitly.
    var_space = []
    comp_variants_n = 2
    # build explicit variant list
    def all_variants(serial, comps, prop):
        out = []
        comp_variants = [comps]
        if len(comps) >= 2:
            comp_variants.append(comps[1:])
        prefixes = [
            [], ["root"], ["dev"], ["root", "dev"], ["dev", serial],
            [serial], ["root", serial], ["root", "dev", serial], ["dev", "root", serial],
        ]
        seps = ["/", ".", ":", ""]
        prop_joins = [".", "/", ":", "", "@", "$", "::"]
        for ci, cv in enumerate(comp_variants):
            for pi, pre in enumerate(prefixes):
                parts = pre + cv
                for si, sep in enumerate(seps):
                    body = sep.join(parts)
                    if not body:
                        continue
                    for ji, pj in enumerate(prop_joins):
                        out.append(((ci, pi, si, ji, False), body + pj + prop))
                        out.append(((ci, pi, si, ji, True), "/" + body + pj + prop))
        return out

    # enumerate variants once on pair 0
    variants0 = all_variants(A, ["hwout", "hwout0"], "gain")
    seen = {}
    for key, s in variants0:
        seen.setdefault(key, s)
    print(f"variant space: {len(seen)} path templates x {len(HASHES)} hashes x 2 encodings")

    # map each variant key -> (its role) and verify the SAME key across all pairs
    for (ci, pi, si, ji, slash), _ in list(seen.items()):
        # build paths for ALL pairs with this key
        paths = []
        ok = True
        for (ser, comps, prop, idhex) in PAIRS:
            cv = [comps, comps[1:] if len(comps) >= 2 else comps][ci]
            prefixes = [
                [], ["root"], ["dev"], ["root", "dev"], ["dev", ser],
                [ser], ["root", ser], ["root", "dev", ser], ["dev", "root", ser],
            ]
            pre = prefixes[pi]
            parts = pre + cv
            sep = ["/", ".", ":", ""][si]
            body = sep.join(parts)
            if not body:
                ok = False
                break
            pj = [".", "/", ":", "", "@", "$", "::"][ji]
            s = body + pj + prop
            if slash:
                s = "/" + s
            paths.append(s)
        if not ok:
            continue
        for hname, hfn in HASHES.items():
            for nullterm in (False, True):
                try:
                    vals = [hfn(p.encode() + (b"\x00" if nullterm else b"")) for p in paths]
                except Exception:
                    continue
                # all 22 must match their targets (either endianness, consistent)
                for endian in ("little", "big"):
                    match = 0
                    for v, (ser, comps, prop, idhex) in zip(vals, PAIRS):
                        t = int.from_bytes(bytes.fromhex(idhex), endian)
                        if v == t:
                            match += 1
                    tested += 1
                    if match >= 3:   # 3+ pairs matching = not coincidence, report
                        print(f"  CANDIDATE {hname} endian={endian} null={nullterm} "
                              f"ci={ci} pi={pi} si={si} ji={ji} slash={slash} "
                              f"-> {match}/{len(PAIRS)} pairs  e.g. '{paths[0]}'")
                    if match == len(PAIRS):
                        print(f"\n*** CRACKED: {hname} endian={endian} null={nullterm} "
                              f"variant ci={ci} pi={pi} si={si} ji={ji} slash={slash}")
                        print(f"    example path: '{paths[0]}'")
                        return True
    print(f"no full match ({tested} combos tested)")
    return False

if __name__ == "__main__":
    main()
