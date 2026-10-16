#!/usr/bin/env python3
"""Watch live setProperty broadcasts from Glue: prints (id, tag, value) for each.
Run this, then change controls in Apogee Control 2 (or on the Quartet touchscreen).
"""
import socket, struct, time, os, sys, importlib.util
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
print(f"watching Glue on port {port}; change controls in Apogee Control 2 now... Ctrl-C to stop")
sock.sendall(probe.juce_wrap(make_record(1, True)))
sock.settimeout(0.5)

buf = b""
TAGS = {1: ("int32", 4), 2: ("int64", 8), 3: ("bool", 1), 4: ("double", 8), 5: ("string", None)}
try:
    while True:
        try:
            d = sock.recv(65536)
            if not d:
                break
            buf += d
        except socket.timeout:
            continue
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC:
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            fr = buf[8:8 + size]
            buf = buf[8 + size:]
            b0 = fr[0]
            typ = b0 & 0x1F
            if typ != 3:
                continue
            sl = {0: 1, 0x40: 2, 0x80: 4}[b0 & 0xC0]
            psize = int.from_bytes(fr[1:1 + sl], "little")
            data = fr[1 + sl + 1:1 + sl + 1 + psize]
            if len(data) < 5:
                continue
            tag = data[0]
            pid = data[1:5]
            val = data[5:]
            tname, tlen = TAGS.get(tag, ("?", None))
            if tag == 4 and len(val) >= 8:
                v = struct.unpack("<d", val[:8])[0]
                print(f"id={pid.hex()} double = {v}")
            elif tag == 3 and val:
                print(f"id={pid.hex()} bool = {val[0]}")
            elif tag == 1 and len(val) >= 4:
                print(f"id={pid.hex()} int32 = {struct.unpack('<i', val[:4])[0]}")
            else:
                print(f"id={pid.hex()} tag={tag} raw={val.hex()}")
except KeyboardInterrupt:
    pass
sock.close()
