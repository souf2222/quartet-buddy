#!/usr/bin/env python3
"""Grid-search the VTS checksum formula against captured frames."""
import os, importlib.util, itertools
spec = importlib.util.spec_from_file_location(
    "ca", os.path.join(os.path.dirname(__file__), "capture_analyzer.py"))
ca = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ca)

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

pairs = []  # (byte0, sizefield_bytes, sizefield_len, payload_after_size incl value bytes, checksum)
for key in order:
    data = b"".join(streams[key])
    for off, fr in ca.juce_frames(data):
        if not fr: continue
        b0 = fr[0]; mask = b0 & 0xC0
        if mask not in (0, 0x40, 0x80): continue
        sl = {0:1, 0x40:2, 0x80:4}[mask]
        size = int.from_bytes(fr[1:1+sl], "little")
        rest = fr[1+sl+size:]
        if len(rest) < 1: continue
        pairs.append((b0, fr[1:1+sl], sl, fr[1+sl:1+sl+size], rest[-1], len(rest)))

# speed: use a representative subset (all bool frames + 40 others), verify winner on all
subset = [p for p in pairs if len(p[3]) == 6][:15] + [p for p in pairs if len(p[3]) == 13][:25] + [p for p in pairs if p[0] & 0x1F == 8][:10]
pairs_eval = subset
print(f"{len(pairs)} samples total, {len(pairs_eval)} in grid search")

def s8(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x80) else x
def s16(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x8000) else x

def make_F(nshift, first_shift, final_xor, use_s8_first=True):
    def F(x):
        t = (x << first_shift) & 0xFFFFFFFF
        if (s8(x) if use_s8_first else s16(x)) < 0:
            t ^= 0x700
        for _ in range(nshift):
            prev = s16(t)
            t = (t << 1) & 0xFFFFFFFF
            if prev < 0:
                t ^= 0x700
        last = s16(t)
        u = t >> 7
        if final_xor and last < 0:
            u ^= 7
        return u & 0xFF
    return F

best = []
total = 0
for nshift in (5, 6, 7):
    for first_shift in (8, 9, 10):
        for final_xor in (True, False):
            F = make_F(nshift, first_shift, final_xor)
            for seed_kind in ("0", "F(b0)", "b0", "F(b0)&0xff"):
                for range_kind in ("b0+size+body", "size+body", "body", "b0+body"):
                    for mode in ("xor_then_F", "F_mixed", "F_b_only"):
                        ok = 0
                        for b0, sf, sl, body, chk, restlen in pairs_eval:
                            if seed_kind == "0": key = 0
                            elif seed_kind == "F(b0)": key = F(b0)
                            elif seed_kind == "b0": key = b0
                            else: key = F(b0) & 0xFF
                            if range_kind == "b0+size+body": buf = bytes([b0]) + sf + body
                            elif range_kind == "size+body": buf = sf + body
                            elif range_kind == "body": buf = body
                            else: buf = bytes([b0]) + body
                            for b in buf:
                                if mode == "xor_then_F":
                                    x = b ^ key
                                    key = F(x)
                                elif mode == "F_mixed":
                                    key = F(b ^ key)
                                else:
                                    x = b ^ key
                                    key = F(b)
                            ok += (key == chk)
                        total += 1
                        best.append((ok, nshift, first_shift, final_xor, seed_kind, range_kind, mode))

best.sort(reverse=True)
for row in best[:12]:
    print(f"match {row[0]}/{len(pairs_eval)}: nshift={row[1]} first={row[2]} finalxor={row[3]} seed={row[4]} range={row[5]} mode={row[6]}")

# verify winner against ALL samples
if best[0][0] > len(pairs_eval) * 0.5:
    ok, nshift, first_shift, final_xor, seed_kind, range_kind, mode = best[0]
    F = make_F(nshift, first_shift, final_xor)
    allok = 0
    for b0, sf, sl, body, chk, restlen in pairs:
        key = 0 if seed_kind == "0" else F(b0) if seed_kind == "F(b0)" else b0
        if range_kind == "b0+size+body": buf = bytes([b0]) + sf + body
        elif range_kind == "size+body": buf = sf + body
        elif range_kind == "body": buf = body
        else: buf = bytes([b0]) + body
        for b in buf:
            if mode == "xor_then_F":
                x = b ^ key; key = F(x)
            elif mode == "F_mixed":
                key = F(b ^ key)
            else:
                x = b ^ key; key = F(b)
        allok += (key == chk)
    print(f"\nWINNER verified on ALL: {allok}/{len(pairs)}")
