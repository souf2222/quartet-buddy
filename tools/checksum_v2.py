#!/usr/bin/env python3
"""Checksum hypothesis v2: running F-state over record bytes (no byte modification)."""
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

def F(x, nshift=6):
    t = (x << 9) & 0xFFFFFFFF
    if s8(x) < 0:
        t ^= 0x700
    for _ in range(nshift):
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
    if key not in streams:
        order.append(key); streams[key] = []
    streams[key].append(payload)

records = []
for key in order:
    data = b"".join(streams[key])
    for off, fr in ca.juce_frames(data):
        if not fr: continue
        b0 = fr[0]; mask = b0 & 0xC0
        if mask not in (0, 0x40, 0x80): continue
        sl = {0:1, 0x40:2, 0x80:4}[mask]
        size = int.from_bytes(fr[1:1+sl], "little")
        body = fr[1+sl:1+sl+size+1]   # size+1 bytes (off-by-one)
        chk = fr[1+sl+size+1:1+sl+size+2]
        if len(chk) != 1: continue
        records.append((bytes([b0]) + fr[1:1+sl] + body, chk[0]))

print(f"{len(records)} (record, checksum) pairs")

def run(rec, seed_mode, nshift):
    if seed_mode == "zero":
        key = 0
        start = 0
    else:  # seed = F(byte0)
        key = F(rec[0], nshift)
        start = 1
    for b in rec[start:]:
        key = F(b ^ key, nshift)
    return key

for nshift in (5, 6, 7):
    for seed_mode in ("zero", "F(b0)"):
        ok = sum(1 for rec, chk in records if run(rec, seed_mode, nshift) == chk)
        print(f"nshift={nshift} seed={seed_mode:6s}: {ok}/{len(records)}")
