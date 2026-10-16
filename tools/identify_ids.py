#!/usr/bin/env python3
"""Identify unknown bool path-ids: set each to 1, diff the tree, restore to 0."""
import socket, struct, time, zlib, os, sys, importlib.util, copy
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
    buf = b""
    frames = []
    end = time.time() + 1.2
    while time.time() < end and len(frames) < 2:
        try:
            d = sock.recv(65536)
            if d: buf += d
        except socket.timeout:
            pass
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

def flat(node, path="", out=None):
    if out is None: out = {}
    p = f"{path}/{node['type']}"
    out[p] = node["props"]
    for c in node["children"]:
        flat(c, p, out)
    return out

def set_bool(id_hex, value):
    sock, _ = probe.connect()
    data = bytes([0x03]) + bytes.fromhex(id_hex) + bytes([value])
    sock.sendall(probe.juce_wrap(make_record(3, False, data)))
    time.sleep(0.8)
    sock.close()

CANDIDATES = ["fe8175b7", "5fa9c0b5", "8f0a6a00", "822c6937"]

base = flat(get_tree())
print("baseline taken")
for cid in CANDIDATES:
    set_bool(cid, 1)
    now = flat(get_tree())
    diffs = []
    for path in set(base) | set(now):
        a = base.get(path, {})
        b = now.get(path, {})
        for k in set(a) | set(b):
            if a.get(k) != b.get(k):
                diffs.append(f"{path}.{k}: {a.get(k)} -> {b.get(k)}")
    print(f"\nid={cid} = 1 changed:")
    for d in diffs:
        print(f"   {d}")
    set_bool(cid, 0)
    time.sleep(0.4)
    restored = flat(get_tree())
    left = []
    for path in set(base) | set(restored):
        a = base.get(path, {})
        b = restored.get(path, {})
        for k in set(a) | set(b):
            if a.get(k) != b.get(k):
                left.append(f"{path}.{k}: {a.get(k)} vs {b.get(k)}")
    if left:
        print(f"   after restore, still differs: {left}")
    else:
        print("   restored cleanly")
    base = flat(get_tree())
