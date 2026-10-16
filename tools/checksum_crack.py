#!/usr/bin/env python3
"""Brute-force the ValueTreeSyncProtocol checksum using captured (record, checksum) pairs."""
import os, importlib.util
spec = importlib.util.spec_from_file_location(
    "ca", os.path.join(os.path.dirname(__file__), "capture_analyzer.py"))
ca = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ca)

def s8(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x80) else x
def s16(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x8000) else x
def F(x):
    t = (x << 9) & 0xFFFFFFFF
    if s8(x) < 0:
        t ^= 0x700
    for _ in range(7):
        prev = s16(t)
        t = (t << 1) & 0xFFFFFFFF
        if prev < 0:
            t ^= 0x700
    last = s16(t)
    u = t >> 7
    if last < 0:
        u ^= 7
    return u & 0xFF

packets = ca.read_pcap("/tmp/apogee_ipc.pcap")
streams = {}
order = []
for ts, pkt, link in packets:
    p = ca.parse_ip(pkt, link)
    if not p: continue
    src, sport, dst, dport, seq, flags, payload = p
    if not payload: continue
    key = (src, sport, dst, dport)
    streams.setdefault(key, []).append(payload)
    if key not in order: order.append(key)

samples = []
for key in order:
    data = b"".join(streams[key])
    for off, fr in ca.juce_frames(data):
        if not fr: continue
        b0 = fr[0]; typ = b0 & 0x1F; mask = b0 & 0xC0
        size_len = {0:1, 0x40:2, 0x80:4}[mask]
        size = int.from_bytes(fr[1:1+size_len], "little")
        body = fr[1:1+size_len+size]          # size bytes + payload (+ value, since size undercounts? no: size = payload len only)
        rest = fr[1+size_len+size:]
        samples.append((typ, b0, fr, body, rest))

# For len13 setProperty: payload(13)=desc(6)+value(7); true value=8 bytes spans into rest[0]; checksum=rest[1]
# => record for checksum purposes = ??? Try candidate regions/seeds.

# collect bool frames: size==6
bool_frames = []
for typ, b0, fr, body, rest in samples:
    if typ != 3: continue
    size = int.from_bytes(body[:1], "little") if (b0 & 0xC0)==0 else None
    if size == 6:
        desc = fr[2:8]; value = rest[0]; chk = rest[1]
        bool_frames.append((b0, size, desc, value, chk))

print(f"{len(bool_frames)} bool frames; e.g. {[ (d.hex(), v, c) for _,_,d,v,c in bool_frames[:4] ]}")

def variants(b0, size, desc, value, chk):
    """Generate candidate byte-ranges and seeds; yield (desc_str, computed)."""
    whole = bytes([b0, size]) + desc + bytes([value])
    cands = {
        "whole seed0": (whole, 0),
        "whole seedF(b0)": (whole, F(b0)),
        "whole seedb0": (whole, b0),
        "after b0 seed0": (bytes([size]) + desc + bytes([value]), 0),
        "desc+val seed0": (desc + bytes([value]), 0),
        "desc seed0 + val?": (desc, 0),
    }
    for name, (buf, seed) in cands.items():
        key = seed
        for b in buf:
            key = F(b ^ key)
        yield name, key

names = None
match_counts = {}
for b0, size, desc, value, chk in bool_frames:
    for name, computed in variants(b0, size, desc, value, chk):
        match_counts.setdefault(name, [0, 0])
        match_counts[name][0] += (computed == chk)
        match_counts[name][1] += 1

for name, (ok, n) in match_counts.items():
    print(f"{name:24s}: {ok}/{n}")

# also try simple XOR/ADD checksums
def xor_all(buf): r=0
for name, fn in [("xor", lambda bs: __import__("functools").reduce(lambda a,b: a^b, bs, 0)),
                 ("sum", lambda bs: sum(bs) & 0xFF),
                 ("neg_xor", lambda bs: (~__import__("functools").reduce(lambda a,b: a^b, bs, 0)) & 0xFF)]:
    ok = sum(1 for b0,size,desc,value,chk in bool_frames if fn(bytes([b0,size])+desc+bytes([value])) == chk)
    print(f"simple {name:8s}: {ok}/{len(bool_frames)}")
