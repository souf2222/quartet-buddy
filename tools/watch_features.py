#!/usr/bin/env python3
"""Watch the glue stream while the user drives the unit's UI.

Logs everything EXCEPT the type-8 meter stream:
  - socket records of every other type (setProperty echoes decoded as
    `id=… tag=… value=…`, plus command/greeting/tree notes),
  - a 0.4 s tree poll diffing the props that matter for the batch:
    hwout1.routeSource (HP source), hwinN.group (ganging), and the
    appState/actionButtons (front-panel touchpad assignments).

Run it, then press things on the touchscreen / Apogee Control 2 / the
front-panel pads. Ctrl-C stops.
"""
import socket, struct, sys, time, zlib, os, importlib.util
sys.path.insert(0, os.path.dirname(__file__))
import jucevt
spec = importlib.util.spec_from_file_location("probe", os.path.join(os.path.dirname(__file__), "probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

FOLD = lambda buf: pp_fold(buf)
def pp_fold(buf):
    key = 0
    for b in buf:
        key = probe.F(b ^ key)
    return key

def make_record(msg_type, flag, data=b""):
    size = len(data)
    mask, sb = (0, 1) if size < 0x100 else ((0x40, 2) if size < 0x10000 else (0x80, 4))
    b0 = (msg_type & 0x1F) | ((1 if flag else 0) << 5) | mask
    sizefield = size.to_bytes(sb, "little")
    body = bytes([pp_fold(bytes([b0]) + sizefield)]) + data
    chk = pp_fold(bytes([b0]) + sizefield + body)
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

def find_type(tree, t):
    def walk(n):
        if (t == "dev" and n["type"].startswith("quartet")) or n["type"] == t:
            return n
        for c in n["children"]:
            r = walk(c)
            if r:
                return r
    return walk(tree)

WATCH_KEYS = ["routeSource", "group", "identify", "actionButton", "pressorNotes"]

def interesting_state(tree):
    out = {}
    dev = find_type(tree, "dev")
    if dev:
        ab = find_type(dev, "actionButtons")
        if ab:
            for c in ab["children"]:
                out[f"touchpad:{c['type']}"] = c["props"].get("actionButton")
        for k, v in sorted(dev["props"].items()):
            out[f"dev.{k}"] = v
        app = find_type(dev, "appState")
        if app:
            for k, v in sorted(app["props"].items()):
                out[f"appState.{k}"] = v
        ms = find_type(dev, "mixers")
        if ms:
            out["mixers.master"] = str(find_type(ms, "master") and find_type(dev, "master")["props"].get("volume"))
    for h in [f"hwout{i}" for i in range(2)]:
        n = find_type(tree, h)
        if n:
            for k, v in sorted(n["props"].items()):
                out[f"{h}.{k}"] = v
    for t in ["hwin0", "hwin1", "hwin2", "hwin3"]:
        n = find_type(tree, t)
        if n:
            for k, v in sorted(n["props"].items()):
                out[f"{t}.{k}"] = v
            msk = find_type(n, "micSettings") or {}
            for k, v in sorted((msk.get("props") or {}).items()):
                out[f"{t}.mic.{k}"] = v
    tb = find_type(tree, "Talkback")
    if tb:
        out["talkback.on"] = tb["props"].get("talkbackOn")
        out["talkback.src"] = tb["props"].get("selectedTalkbackSourceDevice")
        out["talkback.dst"] = tb["props"].get("selectedTalkbackDestinationDevice")
    # the messenger's button subtree — where pad assignments may live
    messenger = find_type(tree, "ApogeeMessenger")
    if messenger:
        mb = find_type(messenger, "messageButtons")
        if mb:
            out["messageButtons.props"] = repr(sorted((mb.get("props") or {}).items()))
            for c in mb["children"]:
                out[f"msgButton:{c['type']}"] = repr(sorted((c.get("props") or {}).items()))
    # the AC2 app node's own props (sometimes carries selection state)
    ac2 = None
    apps = find_type(tree, "Apps")
    for c in (apps["children"] if apps else []):
        if c["type"] == "Apogee Control 2":
            ac2 = c
    if ac2:
        for k, v in sorted(ac2["props"].items()):
            out[f"ac2.{k}"] = v
    return out

ts0 = time.time()
def stamp():
    return f"[{time.time() - ts0:6.1f}s]"

sock, frames = connect_and_hello()
tree = parse_tree(frames)
if tree is None:
    raise SystemExit("no tree — is the Quartet connected?")
print(f"{stamp()} watcher up; baseline state:")
for k, v in interesting_state(tree).items():
    print(f"  {k} = {v}")

sock.settimeout(0.2)
buf = b""
last_state = interesting_state(tree)
last_poll = 0.0
while True:
    try:
        d = sock.recv(65536)
        if not d:
            print(f"{stamp()} socket closed"); break
        buf += d
    except socket.timeout:
        pass
    except OSError as e:
        print(f"{stamp()} socket error {e}"); break
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
        if t == 8:
            continue                         # meter stream — quiet
        sl = {0: 1, 0x40: 2, 0x80: 4}[fr[0] & 0xC0]
        ln = int.from_bytes(fr[1:1 + sl], "little")
        data = fr[1 + sl + 1:1 + sl + 1 + ln]
        if t == 3 and data:
            tag = data[0]
            pid = data[1:5].hex()
            val = data[5:]
            if tag == 1:
                val = struct.unpack("<i", val)[0]
            elif tag == 4:
                val = struct.unpack("<d", val)[0]
            elif tag == 5:
                val = val.rstrip(b"\0").decode(errors="replace")
            elif tag in (2, 3):
                val = "true" if tag == 2 else "false"
            print(f"{stamp()} setProperty (echo) id={pid} tag={tag} value={val!r}")
        elif t == 6:
            print(f"{stamp()} setEntireTree")
        elif t == 2:
            print(f"{stamp()} setTree len={len(data)}")
        elif t == 7:
            print(f"{stamp()} COMMAND {data!r}")
        else:
            print(f"{stamp()} record type={t} len={ln}")
    # 0.4 s tree poll: diff interesting props
    now = time.time()
    if now - last_poll > 0.4:
        last_poll = now
        sock.sendall(probe.juce_wrap(make_record(1, True)))
        sock.settimeout(0.3)
        rbuf = b""
        frames2 = []
        end = time.time() + 0.35
        while time.time() < end and not frames2:
            try:
                rbuf += sock.recv(65536)
            except socket.timeout:
                pass
            while len(rbuf) >= 8:
                magic, size = struct.unpack("<II", rbuf[:8])
                if magic != probe.MAGIC:
                    rbuf = rbuf[1:]
                    continue
                if len(rbuf) < 8 + size:
                    break
                frames2.append(rbuf[8:8 + size])
                rbuf = rbuf[8 + size:]
        tree = parse_tree(frames2)
        if tree:
            st = interesting_state(tree)
            for k, v in st.items():
                if last_state.get(k) != v:
                    print(f"{stamp()} TREE CHANGE {k}: {last_state.get(k)!r} → {v!r}")
            last_state = st
