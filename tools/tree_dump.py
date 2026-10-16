#!/usr/bin/env python3
"""Connect to Glue, request the tree, decompress and dump it + the indexed path map."""
import socket, struct, time, zlib, os, importlib.util
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def fold(buf, key=0):
    for b in buf:
        key = probe.F(b ^ key)
    return key

def make_record(msg_type, flag, data=b""):
    size = len(data)
    if size < 0x100:
        mask, sb = 0, 1
    elif size < 0x10000:
        mask, sb = 0x40, 2
    else:
        mask, sb = 0x80, 4
    b0 = (msg_type & 0x1F) | ((1 if flag else 0) << 5) | mask
    sizefield = size.to_bytes(sb, "little")
    keybyte = fold(bytes([b0]) + sizefield)
    body = bytes([keybyte]) + data
    chk = fold(bytes([b0]) + sizefield + body)
    return bytes([b0]) + sizefield + body + bytes([chk])

sock, port = probe.connect()
print(f"connected on {port}")
sock.sendall(probe.juce_wrap(make_record(1, True)))
sock.settimeout(3.0)
frames = []
buf = b""
end = time.time() + 3
while time.time() < end:
    try:
        d = sock.recv(65536)
        if not d:
            break
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
        if len(frames) >= 3:
            break
    if len(frames) >= 3:
        break
sock.close()

outdir = os.path.join(os.path.dirname(__file__), "..", "docs", "captures")
os.makedirs(outdir, exist_ok=True)

for fr in frames:
    b0 = fr[0]
    typ = b0 & 0x1F
    mask = b0 & 0xC0
    sl = {0: 1, 0x40: 2, 0x80: 4}[mask]
    size = int.from_bytes(fr[1:1 + sl], "little")
    data = fr[1 + sl + 1:1 + sl + 1 + size]   # skip keybyte
    print(f"\n=== type {typ} ({probe.TYPES.get(typ)}) size={size} ===")
    if typ == 6:
        xml = zlib.decompress(data, 16 + zlib.MAX_WBITS)
        open(os.path.join(outdir, "entire_tree.xml"), "w").write(xml.decode())
        print(xml.decode()[:3000])
    elif typ == 9:
        raw = zlib.decompress(data)
        open(os.path.join(outdir, "indexed_paths.bin"), "wb").write(raw)
        print("raw:", raw.hex(" "))
        print("raw ascii:", "".join(chr(c) if 32 <= c < 127 else "." for c in raw))
