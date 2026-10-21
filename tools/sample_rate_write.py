#!/usr/bin/env python3
"""Sample-rate write test against ApogeeGlue.

The captured tree shows the Quartet's device node carrying a `samplerate`
property (JUCE double):

    <quartet1528B15CEE547FA ... samplerate="44100.0" ...>

so the write should be a plain setProperty, path-id = java31 hash of
/dev/<serial>/samplerate, var-tag 4 (double).

Usage:
  python3 sample_rate_write.py 48000      # read current, write target, verify
  python3 sample_rate_write.py --read     # read-only
"""
import socket, struct, sys, time, zlib, os, importlib.util
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

def java31(path):
    h = 0
    for b in path.encode():
        h = (h * 31 + b) & 0xFFFFFFFF
    if h >= 0x80000000:
        h -= 0x100000000
    return struct.pack("<I", h & 0xFFFFFFFF)

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

def find_device(tree):
    def walk(n):
        if n["type"].startswith("quartet"):
            return n
        for c in n["children"]:
            r = walk(c)
            if r:
                return r
    return walk(tree)

def watch(sock, seconds, label):
    """Dump incoming records (echoes / tree updates) for a few seconds."""
    sock.settimeout(0.3)
    end = time.time() + seconds
    buf = b""
    seen = []
    while time.time() < end:
        try:
            d = sock.recv(65536)
            if d:
                buf += d
        except socket.timeout:
            continue
        except OSError:
            break
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC:
                buf = buf[1:]
                continue
            if len(buf) < 8 + size:
                break
            fr = buf[8:8 + size]
            buf = buf[8 + size:]
            t = fr[0] & 0x1F
            if t == 3:   # setProperty echo
                sl = {0: 1, 0x40: 2, 0x80: 4}[fr[0] & 0xC0]
                ln = int.from_bytes(fr[1:1 + sl], "little")
                payload = fr[1 + sl + 1:1 + sl + 1 + ln]
                tag = payload[0]
                pid = payload[1:5].hex()
                val = payload[5:]
                if tag == 4:
                    val = struct.unpack("<d", val)[0]
                elif tag in (1,):
                    val = struct.unpack("<i", val)[0]
                line = f"  [{label}] setProperty id={pid} tag={tag} value={val}"
                if line not in seen:
                    seen.append(line)
                    print(line)
            elif t == 6:
                print(f"  [{label}] setEntireTree (tree refresh)")
            # meters stay quiet by type 8 filtering
    return seen

def coreaudio_rate():
    """The live CoreAudio nominal rate of the Quartet (for cross-check)."""
    import subprocess
    out = subprocess.run(["system_profiler", "SPAudioDataType", "-detailLevel", "full"],
                         capture_output=True, text=True, timeout=20).stdout
    # crude: the rates after the Quartet device's heading (detailLevel full
    # puts the device's properties in the block(s) right after "Quartet:")
    import re
    i = out.find("Quartet:")
    if i >= 0:
        m = re.search(r"Current Sample[Rr]ate.*?:\s*\(?([\d.]+)", out[i:i + 800])
        if m:
            return m.group(1)
    return None

def main():
    sock, frames = connect_and_hello()
    tree = parse_tree(frames)
    if tree is None:
        raise SystemExit("no tree received — is Apogee Control 2 running?")
    dev = find_device(tree)
    serial = dev["type"]
    before = dev["props"].get("samplerate")
    print(f"connected · device = {serial}")
    print(f"tree samplerate BEFORE = {before} · CoreAudio reports {coreaudio_rate()}")

    if len(sys.argv) < 2 or sys.argv[1] == "--read":
        sock.close()
        return

    target = float(sys.argv[1])
    rate_id = java31(f"/dev/{serial}/samplerate")
    print(f"samplerate path-id = {rate_id.hex()} (java31 of /dev/{serial}/samplerate)")
    sock.sendall(probe.juce_wrap(make_record(3, False, bytes([0x04]) + rate_id + struct.pack("<d", target))))
    print(f"sent setProperty samplerate -> {target}")
    watch(sock, 3.0, "write")

    # re-read the tree from a fresh connection
    sock2, frames2 = connect_and_hello()
    tree2 = parse_tree(frames2)
    dev2 = find_device(tree2)
    after = dev2["props"].get("samplerate")
    print(f"tree samplerate AFTER = {after} · CoreAudio reports {coreaudio_rate()}")
    if after is not None and abs(float(after) - target) < 0.5:
        print("WRITE ACCEPTED by Glue tree ✓")
        if before is not None:
            print(f"(restore with: python3 {sys.argv[0]} {float(before):.0f})")
    else:
        print("WRITE did not apply — samplerate is likely display-only over Glue")
    sock.close(); sock2.close()

if __name__ == "__main__":
    main()