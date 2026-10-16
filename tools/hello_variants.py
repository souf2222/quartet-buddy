#!/usr/bin/env python3
"""Try several getEntireTree hello variants against Glue; report which get responses."""
import socket, struct, time, os, importlib.util
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def attempt(name, body, typ=1, flag=True, wait=3.0):
    try:
        sock, port = probe.connect()
    except SystemExit:
        return
    rec = probe.make_record(typ, flag, body)
    try:
        sock.sendall(probe.juce_wrap(rec))
        sock.settimeout(wait)
        data = b""
        end = time.time() + wait
        while time.time() < end:
            try:
                d = sock.recv(65536)
                if d:
                    data += d
            except socket.timeout:
                break
    finally:
        sock.close()
    status = f"{len(data)} bytes" if data else "no response"
    print(f"{name:44s} body={body[:40].hex(' ')[:60]:60s} -> {status}")
    if data:
        n = 0
        buf = data
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC:
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            payload = buf[8:8 + size]
            buf = buf[8 + size:]
            n += 1
            b0 = payload[0]
            typ = b0 & 0x1F
            mask = b0 & 0xC0
            sl = {0: 1, 0x40: 2, 0x80: 4}.get(mask, 1)
            psize = int.from_bytes(payload[1:1+sl], "little")
            body2 = payload[1+sl:1+sl+psize+1]
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in body2[:400])
            print(f"   [{n}] type={typ} size={psize} ascii={txt[:200]}")
    return data

variants = [
    ("empty string", b"\x00"),
    ("root name", b"quartet1528B15CEE547FA\x00"),
    ("tag+root", b"\x0dquartet1528B15CEE547FA\x00"),
    ("app name", b"Apogee Control 2\x00"),
    ("helper name", b"ApogeeTalkbackHelper\x00"),
    ("buddy name", b"QuartetBuddy\x00"),
]
for name, body in variants:
    attempt(name, body)
