#!/usr/bin/env python3
"""Verify the console-learned input ids for hwin0 (Analog IN 1):
write a test value to each id, re-read the tree, report what changed.
Restores every value it changed."""
import socket, struct, time, zlib, os, sys, importlib.util
sys.path.insert(0, os.path.dirname(__file__))
import jucevt
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def fold(buf, key=0):
    for b in buf:
        key = probe.F(b ^ key)
    return key

def make_record(msg_type, flag, data=b""):
    size = len(data)
    mask, sb = (0, 1) if size < 0x100 else ((0x40, 2) if size < 0x10000 else (0x80, 4))
    b0 = (msg_type & 0x1F) | ((1 if flag else 0) << 5) | mask
    sizefield = size.to_bytes(sb, "little")
    body = bytes([fold(bytes([b0]) + sizefield)]) + data
    chk = fold(bytes([b0]) + sizefield + body)
    return bytes([b0]) + sizefield + body + bytes([chk])

def session():
    sock, _ = probe.connect()
    sock.sendall(probe.juce_wrap(make_record(1, True)))
    sock.settimeout(1.2)
    buf, frames, end = b"", [], time.time() + 1.2
    while time.time() < end and len(frames) < 2:
        try:
            d = sock.recv(65536)
            if d: buf += d
        except socket.timeout: pass
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC: buf = buf[1:]; continue
            if len(buf) < 8 + size: break
            frames.append(buf[8:8 + size]); buf = buf[8 + size:]
    return sock, frames

def get_tree():
    _, frames = session()
    for fr in frames:
        if (fr[0] & 0x1F) != 6: continue
        sl = {0: 1, 0x40: 2, 0x80: 4}[fr[0] & 0xC0]
        size = int.from_bytes(fr[1:1 + sl], "little")
        raw = zlib.decompress(fr[1 + sl + 1:1 + sl + 1 + size])
        return jucevt.Reader(raw).tree()
    return None

def find(tree, t):
    if tree["type"] == t: return tree
    for c in tree["children"]:
        r = find(c, t)
        if r: return r
    return None

def hwin0(tree):
    return find(tree, "hwin0")

def snapshot(tree):
    n = hwin0(tree)
    mic = find(n, "micSettings"); inst = find(n, "instSettings")
    mp = mic["props"] if mic else {}
    ip = inst["props"] if inst else {}
    return {
        "refLevel": n["props"].get("analogRefLevel"),
        "softLimit": n["props"].get("softLimit"),
        "polarity": n["props"].get("polarityInvert"),
        "mic.phantom": mp.get("phantom"),
        "mic.gain": find(mic, "PreModelQuartet")["props"].get("gain") if mic else None,
        "inst.gain": find(inst, "PreModelQuartet")["props"].get("gain") if inst else None,
    }

def write(id_hex, tag, packed):
    sock, _ = probe.connect()
    sock.sendall(probe.juce_wrap(make_record(3, False, bytes([tag]) + bytes.fromhex(id_hex) + packed)))
    time.sleep(0.7)
    sock.close()

def diff(a, b):
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append(f"   {k}: {a.get(k)} -> {b.get(k)}")
    return out

MIC_ID, INST_ID, REFLEVEL_ID = "863e271c", "f1e02cb3", "07511d73"

print("== baseline ==")
base = snapshot(get_tree())
for k, v in base.items(): print(f"   {k} = {v}")

print("\n== test 1: write 30.0 dB to learned MIC gain id ==")
write(MIC_ID, 4, struct.pack("<d", 30.0))
after = snapshot(get_tree())
print("\n".join(diff(base, after)) or "   (no change)")

print("\n== test 2: write 10.0 dB to learned INST gain id ==")
write(INST_ID, 4, struct.pack("<d", 10.0))
after2 = snapshot(get_tree())
print("\n".join(diff(after, after2)) or "   (no change)")

print("\n== restore gains ==")
write(MIC_ID, 4, struct.pack("<d", float(base["mic.gain"])))
write(INST_ID, 4, struct.pack("<d", float(base["inst.gain"])))
print("   restored mic=%.4f inst=%.4f" % (base["mic.gain"], base["inst.gain"]))

print("\n== test 3: write refLevel=2 then restore ==")
write(REFLEVEL_ID, 1, struct.pack("<i", 2))
after3 = snapshot(get_tree())
print("\n".join(diff(snapshot(get_tree()), after3)) or "   (no change)")
print("   refLevel now:", after3["refLevel"])
write(REFLEVEL_ID, 1, struct.pack("<i", int(base["refLevel"])))
final = snapshot(get_tree())
print("\n== final vs baseline ==")
print("\n".join(diff(base, final)) or "   identical — all restored")
