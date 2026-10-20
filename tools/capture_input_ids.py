#!/usr/bin/env python3
"""Correlating id-capturer: watches setProperty events AND tree snapshots.
Wiggle controls one input at a time in Apogee Control 2 — every property
change in the tree is matched to the id that caused it, disambiguating
same-typed controls (phantom vs soft limit vs polarity) without following
a strict per-control order.

Usage: python3 capture_input_ids.py [seconds]
"""
import socket, struct, time, zlib, os, sys, importlib.util, threading, json
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

def new_sock():
    s, _ = probe.connect()
    s.sendall(probe.juce_wrap(make_record(1, True)))
    return s

TAGS = {1: 4, 2: 8, 3: 1, 4: 8, 5: None}

# event collector: every setProperty from the shared broadcast stream
events = []            # (t, id_hex, tag, value_float_or_None)
events_lock = threading.Lock()

def event_reader():
    s = new_sock()
    s.settimeout(0.5)
    buf = b""
    while True:
        try:
            d = s.recv(65536)
            if not d:
                s.close(); s = new_sock(); continue
            buf += d
        except socket.timeout:
            continue
        except OSError:
            return
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC:
                buf = buf[1:]; continue
            if len(buf) < 8 + size:
                break
            fr = buf[8:8 + size]
            buf = buf[8 + size:]
            b0 = fr[0]
            if (b0 & 0x1F) != 3:
                continue
            sl = {0: 1, 0x40: 2, 0x80: 4}[b0 & 0xC0]
            psize = int.from_bytes(fr[1:1 + sl], "little")
            data = fr[1 + sl + 1:1 + sl + 1 + psize]
            if len(data) < 5:
                continue
            tag = data[0]
            pid = data[1:5].hex()
            val = data[5:]
            v = None
            if tag == 4 and len(val) >= 8: v = struct.unpack("<d", val[:8])[0]
            elif tag == 1 and len(val) >= 4: v = float(struct.unpack("<i", val[:4])[0])
            elif tag == 3 and val: v = float(val[0])
            with events_lock:
                events.append((time.time(), pid, tag, v))

def get_tree():
    s = new_sock()
    s.settimeout(1.2)
    buf, frames, end = b"", [], time.time() + 1.2
    while time.time() < end and len(frames) < 2:
        try:
            d = s.recv(65536)
            if d: buf += d
        except socket.timeout: pass
        while len(buf) >= 8:
            magic, size = struct.unpack("<II", buf[:8])
            if magic != probe.MAGIC: buf = buf[1:]; continue
            if len(buf) < 8 + size: break
            frames.append(buf[8:8 + size]); buf = buf[8 + size:]
    s.close()
    for fr in frames:
        if (fr[0] & 0x1F) != 6: continue
        sl = {0: 1, 0x40: 2, 0x80: 4}[fr[0] & 0xC0]
        size = int.from_bytes(fr[1:1 + sl], "little")
        raw = zlib.decompress(fr[1 + sl + 1:1 + sl + 1 + size])
        return jucevt.Reader(raw).tree()
    return None

def find(tree, t):
    if tree["type"] == t: return tree
    for c in tree["children"]:
        r = find(c, t)
        if r: return r
    return None

def flatten(tree):
    """hwin/hwout props we care about -> {path: value}"""
    out = {}
    for i in range(4):
        n = find(tree, f"hwin{i}")
        if not n: continue
        out[f"hwin{i}.analogRefLevel"] = n["props"].get("analogRefLevel")
        out[f"hwin{i}.softLimit"] = n["props"].get("softLimit")
        out[f"hwin{i}.polarityInvert"] = n["props"].get("polarityInvert")
        mic = find(n, "micSettings") or {"props": {}, "children": []}
        out[f"hwin{i}.mic.phantom"] = mic["props"].get("phantom")
        pre = find(mic, "PreModelQuartet")
        out[f"hwin{i}.mic.gain"] = pre["props"].get("gain") if pre else None
        inst = find(n, "instSettings")
        pre = find(inst, "PreModelQuartet") if inst else None
        out[f"hwin{i}.inst.gain"] = pre["props"].get("gain") if pre else None
    for o in range(2):
        n = find(tree, f"hwout{o}")
        if not n: continue
        for p in ("gain", "mute", "dim", "sum"):
            out[f"hwout{o}.{p}"] = n["props"].get(p)
    return out

# how a flattened tree prop maps to the app's DeviceTable key
def table_key(path):
    if ".mic.phantom" in path: return ("hwinPhantom", int(path[4]))
    if ".mic.gain" in path: return ("hwinMicGain", int(path[4]))
    if ".inst.gain" in path: return ("hwinInstGain", int(path[4]))
    if ".analogRefLevel" in path: return ("hwinRefLevel", int(path[4]))
    if ".softLimit" in path: return ("hwinSoftLimit", int(path[4]))
    if ".polarityInvert" in path: return ("hwinPolarity", int(path[4]))
    if "hwout" in path and ".sum" in path: return (f"hwout{path[5]}.Sum".replace("hwout0.Sum", "hwout0Sum").replace("hwout1.Sum", "hwout1Sum"), None)
    if "hwout" in path and ".dim" in path: return (f"hwout{path[5]}Dim", None)
    return (None, None)

def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 300
    t = threading.Thread(target=event_reader, daemon=True)
    t.start()
    prev = flatten(get_tree())
    print(f"baseline: {len(prev)} props tracked. Wiggle controls in Apogee Control 2 — one at a time.")
    print(f"listening for {seconds:.0f}s… Ctrl-C to stop early.\n")
    captured = {}
    end = time.time() + seconds
    last_seen_idx = 0
    try:
        while time.time() < end:
            time.sleep(1.0)
            tree = get_tree()
            if not tree: continue
            now = flatten(tree)
            with events_lock:
                evs = events[:]
            new_idx = len(evs)
            changed = [p for p in now if prev.get(p) != now.get(p)]
            if not changed:
                last_seen_idx = new_idx
                continue
            # events in the window since the last snapshot
            window = evs[last_seen_idx:]
            for p in changed:
                # match by value: the LAST event for each id whose value
                # matches the new tree value (tree stores float32-rounded)
                best = None
                for (ts, pid, tag, v) in reversed(window):
                    if v is None: continue
                    nv = now.get(p)
                    if nv is None: continue
                    try:
                        if abs(float(nv) - float(v)) < 0.01:
                            best = pid
                            break
                    except (TypeError, ValueError):
                        continue
                key, idx = table_key(p)
                if best and key:
                    if captured.get((key, idx)) != best:
                        captured[(key, idx)] = best
                        print(f"  captured {key}[{idx}] = {best}   ({p}: {prev.get(p)} -> {now.get(p)})")
                elif not best:
                    print(f"  ? {p}: {prev.get(p)} -> {now.get(p)} (no matching event — tree-only change)")
            prev = now
            last_seen_idx = new_idx
    except KeyboardInterrupt:
        pass
    print("\n=== captured ids ===")
    for (key, idx), pid in sorted(captured.items(), key=lambda kv: (kv[0][0], kv[0][1] or -1)):
        suffix = f"[{idx}]" if idx is not None else ""
        print(f"  {key}{suffix} = {pid}")
    print("\npaste into PathIds (DeviceTable):")
    for (key, idx), pid in sorted(captured.items()):
        if idx is None:
            print(f'        {key}: [UInt8](arrayLiteral: {", ".join("0x" + pid[i:i+2] for i in range(0, 8, 2))}),')
    print("    dict entries:")
    for (key, idx), pid in sorted(captured.items()):
        if idx is not None:
            print(f'        {key}[{idx}] = [UInt8](arrayLiteral: {", ".join("0x" + pid[i:i+2] for i in range(0, 8, 2))})')

if __name__ == "__main__":
    main()
