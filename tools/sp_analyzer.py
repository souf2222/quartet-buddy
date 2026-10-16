#!/usr/bin/env python3
"""Deep-dive on setProperty frames from the capture."""
import struct, sys, os
from collections import Counter

sys.path.insert(0, os.path.dirname(__file__))
import importlib.util
spec = importlib.util.spec_from_file_location("ca", os.path.join(os.path.dirname(__file__), "capture_analyzer.py"))
ca = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ca)

packets = ca.read_pcap("/tmp/apogee_ipc.pcap")
streams = {}
order = []
for ts, pkt, link in packets:
    p = ca.parse_ip(pkt, link)
    if not p:
        continue
    src, sport, dst, dport, seq, flags, payload = p
    if not payload:
        continue
    key = (src, sport, dst, dport)
    if key not in streams:
        order.append(key)
        streams[key] = []
    streams[key].append(payload)

records = []
for key in order:
    data = b"".join(streams[key])
    for off, fr in ca.juce_frames(data):
        if not fr:
            continue
        b0 = fr[0]
        typ = b0 & 0x1F
        mask = b0 & 0xC0
        size_len = {0: 1, 0x40: 2, 0x80: 4}[mask]
        size = int.from_bytes(fr[1:1 + size_len], "little")
        payload = fr[1 + size_len:1 + size_len + size]
        trailer = fr[1 + size_len + size:]
        records.append((key, typ, b0, size, payload, trailer))

print(f"total records: {len(records)}")
print("trailer lengths:", Counter(len(t) for *_, t in records))
sp = [r for r in records if r[1] == 3]
print(f"setProperty records: {len(sp)}")
print("payload lengths:", Counter(len(p) for _, _, _, _, p, _ in sp))
print("trailer samples:", [t.hex() for *_, t in sp[:5]])

print("\n--- setProperty payloads (len 13) ---")
for key, typ, b0, size, p, tr in sp:
    if len(p) != 13:
        print(f"ODD LEN {len(p)}: {p.hex()} trailer={tr.hex()}")
        continue
    desc = p[:6]
    var = p[6:]
    f_le = struct.unpack("<f", var[-4:])[0]
    f_all = struct.unpack("<d", var)[0] if len(var) == 8 else None
    # trailer might eat into var; also print with trailer merged
    merged = p + tr
    f_merged = struct.unpack("<f", merged[-5:-1])[0]
    print(f"desc={desc.hex()} var={var.hex()} | tailfloat={f_le:9.4f} mergedfloat={f_merged:9.4f} | trailer={tr.hex()}")
    if len(sp) > 60 and records.index((key, typ, b0, size, p, tr)) > 200:
        break
