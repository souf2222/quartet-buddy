#!/usr/bin/env python3
# sweep_round3.py — the RIGOROUS decode: 8 s pauses (the flush interval is
# ~9 s but a completed flush frees the next), so every captured write maps
# 1:1 to its set. The pads redo + the routing candidates.
import sys, time, struct
sys.path.insert(0, "/Users/soufiane/GitHub/quartet-buddy/tools")
import importlib.util
spec = importlib.util.spec_from_file_location("pp", "/Users/soufiane/GitHub/quartet-buddy/tools/prop_probe.py")
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)

PAUSE = 8.0

def mark(msg):
    line = f"{time.time():.3f}  {msg}"
    print(line, flush=True)
    with open("/tmp/sweep_timeline.txt", "a") as f:
        f.write(line + "\n")

sock, frames = pp.connect_and_hello()
tree = pp.parse_tree(frames)
dev = pp.find_type(tree, "dev")
serial = dev["type"]
mark(f"SERIAL {serial}")

def setprop(rel, v, tag=1, data=None):
    pid = pp.dev_path(serial, rel)
    pp.apply_write(sock, pid, tag, data if data else pp.int_data(v))
    mark(f"R3B {rel} = {v}")
    time.sleep(PAUSE)

# ── 1. the pads REDO (the tail was lag-corrupted) ──
pad_codes = [0x20002, 0x20003, 0x20004, 0x30002, 0x30003, 0x30004,
             0x40002, 0x40003, 0x40004, 0x5000B, 0x5000C, 0x60001,
             0x70005, 0x70006]
for c in pad_codes:
    setprop("appState/actionButtons/Touchpad_A/actionButton", c)
setprop("appState/actionButtons/Touchpad_A/actionButton", 131076)   # restore

# ── 2. the routing on hwout2 (Analog Out 1): the playback anchors + the mixer space ──
routecodes = [
    (0x10000000, "PB1-2"), (0x10000002, "PB3-4"), (0x10000004, "PB5-6"), (0x10000006, "PB7-8"),
]
for t in range(0x11, 0x1C):   # the source-type sweep, plain + master-ch forms
    routecodes.append((t << 24, f"type{t:#x}"))
    routecodes.append(((t << 24) | 0x0d, f"type{t:#x}+ch13"))
    routecodes.append(((t << 24) | 0x1b, f"type{t:#x}+ch27"))
for c, label in routecodes:
    setprop("hwout/hwout2/routeSource", c)
setprop("hwout/hwout2/routeSource", 0x10000000)   # restore

sock.close()
mark("R3B-DONE")
print("round 3b complete")
