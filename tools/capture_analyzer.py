#!/usr/bin/env python3
"""
Analyze a tcpdump capture of ApogeeGlue IPC traffic (loopback, JUCE
InterprocessConnection + Apogee ValueTreeSyncProtocol).

Usage:
    sudo tcpdump -i lo0 -s0 -w /tmp/apogee_ipc.pcap tcp port 53435
    python3 capture_analyzer.py /tmp/apogee_ipc.pcap

Parses classic pcap (DLT_NULL / DLT_EN10MB), reassembles TCP streams,
extracts JUCE frames (magic FFFF9E2C) and attempts to decode the
ValueTreeSyncProtocol envelope + keystream.
"""
import struct
import sys

MAGIC_JUCE = 0xF2B49E2C  # mov x9,#-0x61d4 ; movk x9,#0xf2b4,lsl#16 -> LE store 2C 9E B4 F2

# ---------------------------------------------------------------- pcap input

def read_pcap(path):
    data = open(path, "rb").read()
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    elif magic == b"\x4d\x3c\xb2\xa1":
        sys.exit("pcapng format not supported — recapture with: tcpdump -F pcap ...")
    else:
        sys.exit(f"not a pcap file (magic {magic!r})")
    vmaj, vmin, tz, sig, snap, link = struct.unpack(endian + "HHiIII", data[4:24])
    off = 24
    packets = []
    while off + 16 <= len(data):
        ts, tu, caplen, wirelen = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkt = data[off:off + caplen]
        off += caplen
        packets.append((ts + tu / 1e6, pkt, link))
    return packets

# ---------------------------------------------------------------- TCP parse

def parse_ip(pkt, link):
    if link == 0:  # DLT_NULL (BSD loopback)
        if len(pkt) < 4:
            return None
        fam = struct.unpack("<I", pkt[:4])[0]
        if fam != 2:  # AF_INET
            return None
        pkt = pkt[4:]
    elif link == 1:  # DLT_EN10MB
        pkt = pkt[14:]
    else:
        return None
    if len(pkt) < 20 or (pkt[0] >> 4) != 4:
        return None
    ihl = (pkt[0] & 0xF) * 4
    proto = pkt[9]
    if proto != 6:  # TCP
        return None
    src = ".".join(str(b) for b in pkt[12:16])
    dst = ".".join(str(b) for b in pkt[16:20])
    tcp = pkt[ihl:]
    if len(tcp) < 20:
        return None
    sport, dport = struct.unpack("!HH", tcp[:4])
    doff = (tcp[12] >> 4) * 4
    payload = tcp[doff:]
    flags = tcp[13]
    seq = struct.unpack("!I", tcp[4:8])[0]
    return (src, sport, dst, dport, seq, flags, payload)

# ------------------------------------------------------------- keystream F()

def s8(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x80) else x

def s16(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if (x & 0x8000) else x

def keystream_step(x):
    """Exactly mirrors the transform applied to each decoded byte in
    Decoder::pushData (tb arm64 0x100043b64..0x100043c08)."""
    t = (x << 9) & 0xFFFFFFFF
    if s8(x) < 0:
        t ^= 0x700
    for _ in range(7):
        prev = s16(t)
        t = (t << 1) & 0xFFFFFFFF
        if prev < 0:
            t ^= 0x700
    last = s16(t)
    u = t >> 7
    if last < 0:
        u ^= 7
    return u & 0xFF

def deobfuscate(buf, seed):
    """x = b ^ key; key = F(x). Returns (plain bytes, final key)."""
    out = bytearray()
    key = seed & 0xFF
    for b in buf:
        x = b ^ key
        out.append(x)
        key = keystream_step(x)
    return bytes(out), key

# ------------------------------------------------------------- JUCE framing

def juce_frames(stream):
    off = 0
    frames = []
    while off + 8 <= len(stream):
        magic, size = struct.unpack("<II", stream[off:off + 8])
        if magic != MAGIC_JUCE:
            off += 1  # resync
            continue
        if size > 64 * 1024 * 1024:
            off += 1
            continue
        if off + 8 + size > len(stream):
            break
        frames.append((off, stream[off + 8:off + 8 + size]))
        off += 8 + size
    return frames

# ------------------------------------------------------------ VTS envelope

TYPES = {1: "getEntireTree", 2: "setTree", 3: "setProperty", 4: "deleteItem",
         5: "type5?", 6: "setEntireTree", 7: "Command", 8: "type8?",
         9: "setIndexedPaths", 10: "treeChildOrderChanged"}

def parse_envelope(plain_or_cipher):
    """Given a VTS message payload (after JUCE header), describe it."""
    if not plain_or_cipher:
        return "empty"
    b0 = plain_or_cipher[0]
    typ = b0 & 0x1F
    flag = (b0 >> 5) & 1
    mask = b0 & 0xC0
    return f"byte0=0x{b0:02x} type={typ}({TYPES.get(typ, '?')}) flag={flag} mask=0x{mask:02x}"

# ------------------------------------------------------------------- main

def main():
    path = sys.argv[1]
    packets = read_pcap(path)
    streams = {}
    order = []
    for ts, pkt, link in packets:
        p = parse_ip(pkt, link)
        if not p:
            continue
        src, sport, dst, dport, seq, flags, payload = p
        if not payload:
            continue
        key = (src, sport, dst, dport)
        if key not in streams:
            order.append(key)
            streams[key] = []
        streams[key].append((seq, payload))

    print(f"{len(packets)} packets, {len(streams)} half-streams\n")
    for key in order:
        segs = streams[key]
        # in-order concatenation (loopback); dedupe exact retransmits
        seen = set()
        parts = []
        last_end = None
        for seq, payload in segs:
            if last_end is not None and seq < last_end:
                continue  # retransmit/overlap
            parts.append(payload)
            last_end = (seq + len(payload)) & 0xFFFFFFFF
        data = b"".join(parts)
        frames = juce_frames(data)
        print("=" * 78)
        print(f"stream {key[0]}:{key[1]} -> {key[2]}:{key[3]}  ({len(data)} bytes, {len(frames)} JUCE frames)")
        print("=" * 78)
        LIMIT = int(__import__("os").environ.get("FRAME_LIMIT", "100000"))
        for off, payload in frames[:LIMIT]:
            print(f"\n--- frame @+{off} len={len(payload)} ---")
            print("  " + parse_envelope(payload))
            hx = payload.hex(" ")
            for i in range(0, len(hx), 96):
                print("   " + hx[i:i + 96])
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in payload)
            print("   ascii: " + txt)
        print()

if __name__ == "__main__":
    main()
