#!/usr/bin/env python3
"""
Probe client for ApogeeGlue IPC.

Connects to the Glue TCP server, sends a getEntireTree hello (type 1),
then dumps everything Glue sends back, decoding the VTS records.

Usage:
  python3 probe.py                # connect, hello, dump for ~20s
  python3 probe.py --watch 60    # watch for 60 seconds
"""
import socket, struct, sys, time, os

HOST = "127.0.0.1"
PORTS = [53435, 61367, 4677, 24110, 36218, 18140, 6414]
MAGIC = 0xF2B49E2C

TYPES = {1: "getEntireTree", 2: "setTree", 3: "setProperty", 4: "deleteItem",
         5: "type5", 6: "setEntireTree", 7: "Command", 8: "meter",
         9: "setIndexedPaths", 10: "childOrderChanged"}

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
    for _ in range(6):
        prev = s16(t)
        t = (t << 1) & 0xFFFFFFFF
        if prev < 0:
            t ^= 0x700
    last = s16(t)
    u = t >> 7
    if last < 0:
        u ^= 7
    return u & 0xFF

def checksum(buf):
    key = 0
    for b in buf:
        key = F(b ^ key)
    return key

def make_record(msg_type, flag, body=b""):
    size = len(body) - 1 if body else 0
    # sizemask: body-1<0x100 -> 0 (1B); <0x10000 -> 0x40 (2B); else 0x80 (4B)
    if len(body) <= 0x100:
        mask, sb = 0, 1
    elif len(body) <= 0x10000:
        mask, sb = 0x40, 2
    else:
        mask, sb = 0x80, 4
    b0 = (msg_type & 0x1F) | ((1 if flag else 0) << 5) | mask
    rec = bytes([b0]) + size.to_bytes(sb, "little") + body
    return rec + bytes([checksum(rec)])

def juce_wrap(payload):
    return struct.pack("<II", MAGIC, len(payload)) + payload

def connect():
    for port in PORTS:
        try:
            s = socket.create_connection((HOST, port), timeout=1.0)
            return s, port
        except OSError:
            continue
    raise SystemExit("no Glue server found on candidate ports")

def recv_records(sock, seconds, out):
    sock.settimeout(0.5)
    buf = b""
    end = time.time() + seconds
    count = 0
    while time.time() < end:
        try:
            d = sock.recv(65536)
            if not d:
                print("[probe] connection closed by Glue")
                return
            buf += d
        except socket.timeout:
            continue
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != MAGIC:
                print("[probe] resync: bad magic", hex(magic))
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            payload = buf[8:8 + size]
            buf = buf[8 + size:]
            count += 1
            dump_record(count, payload, out)

def dump_record(n, rec, out):
    b0 = rec[0]
    typ = b0 & 0x1F
    flag = (b0 >> 5) & 1
    mask = b0 & 0xC0
    sl = {0: 1, 0x40: 2, 0x80: 4}.get(mask)
    if sl is None:
        out(f"[{n}] bad mask {mask:02x}: {rec.hex()}")
        return
    size = int.from_bytes(rec[1:1+sl], "little")
    body = rec[1+sl:1+sl+size+1]
    chk = rec[1+sl+size+1:1+sl+size+2]
    ok = checksum(bytes(rec[:1+sl+size+1])) == (chk[0] if chk else -1)
    name = TYPES.get(typ, f"t{typ}")
    txt = "".join(chr(c) if 32 <= c < 127 else "." for c in body[:300])
    out(f"[{n}] type={typ}({name}) flag={flag} size={size} chk={'OK' if ok else 'BAD'} len={len(rec)}")
    out(f"     body[:64]={body[:64].hex(' ')}")
    if any(32 <= c < 127 for c in body[:200]):
        out(f"     ascii: {txt}")

def main():
    watch = 20
    if "--watch" in sys.argv:
        watch = int(sys.argv[sys.argv.index("--watch") + 1])
    lines = []
    def out(s):
        print(s)
        lines.append(s)

    sock, port = connect()
    out(f"[probe] connected to Glue on port {port}")

    hello = make_record(1, True)          # getEntireTree, flag=1, empty body
    out(f"[probe] sending hello: {hello.hex(' ')}")
    sock.sendall(juce_wrap(hello))

    recv_records(sock, watch, out)
    sock.close()
    path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "probe_dump.txt")
    open(path, "w").write("\n".join(lines))
    print(f"\n[probe] saved to {path}")

if __name__ == "__main__":
    main()
