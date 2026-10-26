#!/usr/bin/env python3
"""Live-verification probe for the "small features" batch (see the plan).

One script for every write the batch introduces — each is a setProperty with
a computed path-id (java31 hash of the slash path), differing only in the
var-tag:

    flag <name> <0|1>            dev node bool (identify, peakHold, overHold,
                                 lockHomeScreen, SafeMode, …)          tag 3
    reflevel <i> <2|3>           hwout<i>.analogRefLevel (+4 dBu/−10 dBV), i = 2..7  tag 1
    buffer <frames>              dev node preferredBufferSize (int32; probe
                                 whether CoreAudio's buffer follows)    tag 1
    rename dev|dev_<x>|hwin<n>|hwout<n> <new name>
                                 a `name` string setProperty            tag 5
    tbsource "<device>" [ch]     talkback helper selectedTalkbackSourceDevice
                                 (string) + …Channel (int) — app-scoped paths

Every op prints the tree value BEFORE, sends the write, watches ~3 s for the
echo, then re-reads the tree from a fresh connection and says whether the
write applied (and how to restore). Add --read to just dump the relevant
state.

Examples:
  python3 prop_probe.py read
  python3 prop_probe.py flag identify 1            # blink the front panel
  python3 prop_probe.py reflevel 2 3               # Analog Out 1 → −10 dBV
  python3 prop_probe.py buffer 256
  python3 prop_probe.py rename hwin0 "Kick"
  python3 prop_probe.py tbsource "MacBook Air Microphone" 0
"""
import socket, struct, sys, time, zlib, os, importlib.util
sys.path.insert(0, os.path.dirname(__file__))
import jucevt
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

FLAGS = ["identify", "peakHold", "overHold", "lockHomeScreen", "safeMode",
         "keyboardVolumeControls", "ignoreSideEffects"]

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

def set_property(pid, tag, raw):
    return make_record(3, False, bytes([tag]) + pid + raw)

def bool_data(on):            return bytes([1] if on else [0])  # setProperty tag-3 value byte: 1/0
def int_data(v):              return struct.pack("<i", int(v))
def string_data(s):
    d = bytearray(s.encode())
    d.append(0)
    return bytes(d)

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

def find_type(tree, t):
    """First node whose type == t (exact) — `dev` walks past the container
    to the actual quartet<serial> node."""
    def walk(n):
        if t == "dev":
            if n["type"].startswith("quartet"):
                return n
        elif n["type"] == t:
            return n
        for c in n["children"]:
            r = walk(c)
            if r:
                return r
    return walk(tree)

def describe_value(v):
    if isinstance(v, bytes):
        return f"bytes({v.hex()})"
    return repr(v)

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
                nice = val
                if tag == 1:
                    nice = struct.unpack("<i", val)[0]
                elif tag == 4:
                    nice = struct.unpack("<d", val)[0]
                elif tag == 5:
                    nice = val.rstrip(b"\0").decode(errors="replace")
                line = f"  [{label}] setProperty id={pid} tag={tag} value={nice!r}"
                if line not in seen:
                    seen.append(line)
                    print(line)
            elif t == 6:
                print(f"  [{label}] setEntireTree (tree refresh)")
    return seen

def read_state(tree, dev, serial):
    print(f"\n== device node {serial} ==")
    for k in ["name", "samplerate", "preferredBufferSize", "supportedBufferSizesBitSet"] + FLAGS:
        if k in dev["props"]:
            print(f"  {k:28} = {describe_value(dev['props'][k])}")
    for t in ["hwin0", "hwin1", "hwin2", "hwin3"]:
        n = find_type(tree, t)
        if n:
            print(f"  {t:28}: name={n['props'].get('name')!r} analogRefLevel={n['props'].get('analogRefLevel')} group={n['props'].get('group')}")
    for t in [f"hwout{i}" for i in range(8)]:
        n = find_type(tree, t)
        if n:
            print(f"  {t:28}: name={n['props'].get('name')!r} analogRefLevel={n['props'].get('analogRefLevel')} "
                  f"routeSource={n['props'].get('routeSource')} trim={n['props'].get('trim')}")
    app = find_type(tree, "Talkback")
    if app:
        print("== Talkback ==")
        for k, v in app["props"].items():
            print(f"  {k:34} = {describe_value(v)}")
        for c in app["children"]:
            print(f"  source {c['type']:26} active={c['props'].get('active')} ch={c['props'].get('numberOfInputChannels')}")

def dev_path(serial, rel):
    pid = java31(f"/dev/{serial}/{rel}")
    print(f"  path-id of /dev/{serial}/{rel} = {pid.hex()}")
    return pid

def app_path(rel):
    pid = java31(f"/Apps/{rel}")
    print(f"  path-id of /Apps/{rel} = {pid.hex()}")
    return pid

def apply_write(sock, pid, tag, raw):
    sock.sendall(probe.juce_wrap(set_property(pid, tag, raw)))
    return watch(sock, 3.0, "write")

def reread():
    sock2, frames2 = connect_and_hello()
    tree2 = parse_tree(frames2)
    sock2.close()
    return tree2

def main():
    sock, frames = connect_and_hello()
    tree = parse_tree(frames)
    if tree is None:
        raise SystemExit("no tree received — is the Quartet connected (and Glue running)?")
    dev = find_type(tree, "dev")
    serial = dev["type"]
    print(f"connected · device = {serial}")

    args = sys.argv[1:]
    if not args or args[0] == "--read":
        read_state(tree, dev, serial)
        sock.close()
        return

    op = args[0]
    tree2 = None
    if op == "flag":
        name, val = args[1], args[2] == "1"
        pid = dev_path(serial, name)
        echo = apply_write(sock, pid, 3, bool_data(val))
        tree2 = reread()
        after = find_type(tree2, "dev")["props"].get(name)
        print(f"tree {name} AFTER = {describe_value(after)}")
        verdict = (on_val(after) == val)
    elif op == "reflevel":
        idx, v = int(args[1]), int(args[2])
        pid = dev_path(serial, f"hwout/hwout{idx}/analogRefLevel")
        echo = apply_write(sock, pid, 1, int_data(v))
        tree2 = reread()
        after = find_type(tree2, f"hwout{idx}")["props"].get("analogRefLevel")
        print(f"tree hwout{idx}.analogRefLevel AFTER = {describe_value(after)}")
        verdict = (after == v)
    elif op == "buffer":
        v = int(args[1])
        pid = dev_path(serial, "preferredBufferSize")
        echo = apply_write(sock, pid, 1, int_data(v))
        tree2 = reread()
        after = find_type(tree2, "dev")["props"].get("preferredBufferSize")
        print(f"tree preferredBufferSize AFTER = {describe_value(after)}")
        if args.count("--coreaudio"):
            import subprocess
            out = subprocess.run(["system_profiler", "SPAudioDataType", "-detailLevel", "full"],
                                 capture_output=True, text=True, timeout=20).stdout
            i = out.find("Quartet")
            print("CoreAudio block:", out[i:i + 400].replace("\n", " | ") if i >= 0 else "Quartet not found")
        verdict = (after == v)
    elif op == "rename":
        target, name = args[1], args[2]
        if target.startswith("hwin"):
            rel = f"hwin/{target}/name"
        elif target.startswith("hwout") and target != "dev":
            rel = f"hwout/{target}/name"
        elif target.startswith("dev"):
            n = target.split("_", 1)[1] if "_" in target else "0"
            rel = "name"
        else:
            raise SystemExit("rename target: dev | hwin0..3 | hwout0..7")
        pid = dev_path(serial, rel)
        echo = apply_write(sock, pid, 5, string_data(name))
        tree2 = reread()
        if rel == "name":
            after = find_type(tree2, "dev")["props"].get("name")
        else:
            parts = rel.split("/")
            after = find_type(tree2, parts[-1])["props"].get("name")
        print(f"tree {rel} AFTER = {describe_value(after)}")
        verdict = (after == name)
    elif op == "tbsource":
        device = args[1]
        channel = int(args[2]) if len(args) > 2 else 0
        pid1 = app_path("Apogee Talkback helper/Talkback/selectedTalkbackSourceDevice")
        echo = apply_write(sock, pid1, 5, string_data(device))
        pid2 = app_path("Apogee Talkback helper/Talkback/selectedTalkbackSourceChannel")
        echo += apply_write(sock, pid2, 1, int_data(channel))
        tree2 = reread()
        tk = find_type(tree2, "Talkback")
        d = tk["props"].get("selectedTalkbackSourceDevice")
        c = tk["props"].get("selectedTalkbackSourceChannel")
        print(f"tree selectedTalkbackSourceDevice/Channel AFTER = {d!r} / {c}")
        verdict = (d == device and str(c) == str(channel))
    else:
        raise SystemExit(__doc__)

    if verdict:
        print("WRITE ACCEPTED by Glue tree ✓")
    else:
        print("WRITE did not apply — check the echo above + docs/protocol-notes.md")
    sock.close()

def on_val(v):
    """Bool/int variations (True/False, 1/0) → True/False, None stays None."""
    if v in (True, 1): return True
    if v in (False, 0): return False
    return v

if __name__ == "__main__":
    main()
