#!/usr/bin/env python3
"""Write test: send setProperty(hwout0.gain) to Glue, then re-read the tree to verify."""
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

def connect_and_hello():
    sock, port = probe.connect()
    sock.sendall(probe.juce_wrap(make_record(1, True)))
    sock.settimeout(1.5)
    buf = b""
    frames = []
    end = time.time() + 1.5
    while time.time() < end and len(frames) < 2:
        try:
            d = sock.recv(65536)
            if d:
                buf += d
        except socket.timeout:
            pass
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC:
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            frames.append(buf[8:8 + size])
            buf = buf[8 + size:]
    return sock, frames

def parse_tree(frames):
    for fr in frames:
        b0 = fr[0]
        if (b0 & 0x1F) != 6:
            continue
        sl = {0: 1, 0x40: 2, 0x80: 4}[b0 & 0xC0]
        size = int.from_bytes(fr[1:1 + sl], "little")
        data = fr[1 + sl + 1:1 + sl + 1 + size]
        raw = zlib.decompress(data)
        return jucevt.Reader(raw).tree()
    return None

def find_hwout(tree, idx):
    def walk(n):
        if n["type"] == f"hwout{idx}":
            return n
        for c in n["children"]:
            r = walk(c)
            if r:
                return r
    return walk(tree)

sock, frames = connect_and_hello()
tree = parse_tree(frames)
hw0 = find_hwout(tree, 0)
gain_before = hw0["props"]["gain"]
print(f"connected; hwout0 (Main Out) gain BEFORE = {gain_before}")

# --- write test: bump gain by +0.5 dB, wait, re-read ---
new_gain = float(gain_before) + 0.5
GAIN_ID = bytes.fromhex("c5a2bdb5")          # hwout0.gain path id (LE)
tag = bytes([0x04])                          # double
value = struct.pack("<d", new_gain)
sock.sendall(probe.juce_wrap(make_record(3, False, tag + GAIN_ID + value)))
print(f"sent setProperty hwout0.gain -> {new_gain}")
time.sleep(1.0)

sock2, frames2 = connect_and_hello()
tree2 = parse_tree(frames2)
hw0b = find_hwout(tree2, 0)
print(f"hwout0 gain AFTER = {hw0b['props']['gain']}")
ok = abs(float(hw0b['props']['gain']) - new_gain) < 0.001
print("WRITE " + ("SUCCEEDED ✓✓✓" if ok else "did not apply"))

# restore
sock2.sendall(probe.juce_wrap(make_record(3, False, tag + GAIN_ID + struct.pack("<d", float(gain_before)))))
print(f"restored gain to {gain_before}")
time.sleep(0.5)
sock.close(); sock2.close()
