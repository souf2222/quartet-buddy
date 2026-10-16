#!/usr/bin/env python3
"""Verify the ValueTreeSyncProtocol codec hypothesis against captured frames."""
import struct, os, importlib.util
from collections import Counter

spec = importlib.util.spec_from_file_location(
    "ca", os.path.join(os.path.dirname(__file__), "capture_analyzer.py"))
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
        rest = fr[1 + size_len + size:]
        records.append((typ, b0, size, payload, rest))

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

def process(buf, seed=0):
    """x = b ^ key; key = F(x). Returns (plain, final_key)."""
    out = bytearray()
    key = seed
    for b in buf:
        x = b ^ key
        out.append(x)
        key = F(x)
    return bytes(out), key

# Hypothesis A: whole record after byte0 is under continuous keystream,
# byte0 plaintext, seed = 0, checksum = final key after all bytes incl. tag.
print("=== setProperty (len13) frames: continuous-keystream check ===")
ok = fail = 0
first = []
for typ, b0, size, p, rest in records:
    if typ != 3 or len(p) != 13:
        continue
    # record bytes: byte0 + size byte + payload + rest[:-1]; checksum = rest[-1]
    rec = bytes([b0]) + size.to_bytes(1, "little") + p + rest[:-1]
    chk = rest[-1]
    plain, final = process(rec, 0)
    if final == chk:
        ok += 1
    else:
        fail += 1
    if len(first) < 6:
        first.append((rec.hex(), chk, final, plain.hex()))
for rec, chk, final, plain in first:
    print(f"  rec={rec}\n    expected_chk={chk:02x} computed={final:02x} {'OK' if chk==final else 'MISMATCH'}\n    plain={plain}")
print(f"  continuous keystream: ok={ok} fail={fail}")

# Hypothesis B: payload-only keystream with seed = 0
print("\n=== payload-only keystream, seed 0 ===")
for typ, b0, size, p, rest in [r for r in records if r[0] == 3][:3]:
    plain, fin = process(p + rest, 0)
    print(f"  cipher={ (p+rest).hex() } plain={plain.hex()} finalkey={fin:02x} (rest={rest.hex()})")

# Hypothesis C: NO obfuscation at all; structure = desc + var
print("\n=== raw structure of len-13 setProperty ===")
for typ, b0, size, p, rest in [r for r in records if r[0] == 3 and len(r[3]) == 13][:12]:
    tail4 = struct.unpack("<f", (p + rest)[9:13])[0]
    print(f"  p={p.hex()} rest={rest.hex()}  float@9={(p+rest)[9:13].hex()}={tail4:8.3f}")

print("\n=== len-6 setProperty frames (mute/talkback?) ===")
for typ, b0, size, p, rest in [r for r in records if r[0] == 3 and len(r[3]) == 6][:20]:
    print(f"  p={p.hex()} rest={rest.hex()}")

print("\n=== type 8 (meter) record tail ===")
for typ, b0, size, p, rest in [r for r in records if r[0] == 8][:3]:
    print(f"  size={size} payloadlen={len(p)} rest={rest.hex()}  payload[-8:]={p[-8:].hex()}")

print("\n=== other types present ===")
print(Counter(r[0] for r in records))
