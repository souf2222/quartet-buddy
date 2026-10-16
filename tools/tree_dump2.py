#!/usr/bin/env python3
"""Fetch the entire tree from Glue, parse the JUCE ValueTree stream, dump as XML."""
import socket, struct, time, zlib, os, importlib.util, sys
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

sock, port = probe.connect()
sock.sendall(probe.juce_wrap(make_record(1, True)))
sock.settimeout(2.5)
buf = b""
frames = []
end = time.time() + 2.5
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
sock.close()

print(f"got {len(frames)} frames")
fr = frames[0]  # setEntireTree
b0 = fr[0]
sl = {0: 1, 0x40: 2, 0x80: 4}[b0 & 0xC0]
size = int.from_bytes(fr[1:1 + sl], "little")
data = fr[1 + sl + 1:1 + sl + 1 + size]
raw = zlib.decompress(data)
print(f"decompressed {len(raw)} bytes")

r = jucevt.Reader(raw)
tree = r.tree()
xml = jucevt.to_xml(tree)
outdir = os.path.join(os.path.dirname(__file__), "..", "docs", "captures")
os.makedirs(outdir, exist_ok=True)
open(os.path.join(outdir, "entire_tree.xml"), "w").write(xml)
print(f"parsed; leftover bytes: {len(raw) - r.p}")
print(xml[:6000])

# frame 2: setIndexedPaths
fr2 = frames[1]
b0 = fr2[0]
sl = {0: 1, 0x40: 2, 0x80: 4}[b0 & 0xC0]
size = int.from_bytes(fr2[1:1 + sl], "little")
data2 = fr2[1 + sl + 1:1 + sl + 1 + size]
raw2 = zlib.decompress(data2)
print("\n=== setIndexedPaths decompressed ===")
print(raw2.hex(" "))
print("".join(chr(c) if 32 <= c < 127 else "." for c in raw2))
