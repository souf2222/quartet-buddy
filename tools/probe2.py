#!/usr/bin/env python3
"""Hello v2: record = [byte0][size][keybyte=fold(byte0+size)][data][chk=fold(all)]"""
import socket, struct, time, os, importlib.util
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

F = probe.F
MAGIC = probe.MAGIC

def fold(buf, key=0):
    for b in buf:
        key = F(b ^ key)
    return key

def make_record_v2(msg_type, flag, data=b""):
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

def attempt(name, rec, wait=4.0):
    try:
        sock, port = probe.connect()
    except SystemExit:
        print("no server")
        return
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
            pass
    sock.close()
    print(f"{name}: rec={rec.hex(' ')} -> {len(data)} bytes")
    if data:
        out = []
        probe_out = lambda s: (print(s), out.append(s))
        buf = data
        n = 0
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != MAGIC:
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            payload = buf[8:8 + size]
            buf = buf[8 + size:]
            n += 1
            probe.dump_record(n, payload, probe_out)
        open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "hello_response.txt"), "w").write("\n".join(out))

hello = make_record_v2(1, True)
attempt("hello v2 (empty data, type1 flag1)", hello)
