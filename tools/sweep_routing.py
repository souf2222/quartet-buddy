#!/usr/bin/env python3
# sweep_routing.py — round 2: the OUTPUT ROUTING codes, the full pad enum,
# and the talkback path, all through the glue while the shim captures.
# Invalid codes are auto-filtered: the daemon refuses them (no USB write,
# the tree reread rejects) — the survivors = the valid source space.
import sys, time, struct
sys.path.insert(0, "/Users/soufiane/GitHub/quartet-buddy/tools")
import importlib.util
spec = importlib.util.spec_from_file_location("pp", "/Users/soufiane/GitHub/quartet-buddy/tools/prop_probe.py")
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)

TIMELINE = "/tmp/sweep_timeline.txt"
PAUSE = 2.5

def mark(msg):
    line = f"{time.time():.3f}  {msg}"
    print(line, flush=True)
    with open(TIMELINE, "a") as f:
        f.write(line + "\n")

sock, frames = pp.connect_and_hello()
tree = pp.parse_tree(frames)
dev = pp.find_type(tree, "dev")
serial = dev["type"]
mark(f"SERIAL {serial}")

def setprop(rel, v):
    """int32 write; returns the AFTER value or None"""
    pid = pp.dev_path(serial, rel)
    pp.apply_write(sock, pid, 1, pp.int_data(v))
    time.sleep(0.6)
    tree2 = pp.reread()
    n = pp.find_type(tree2, "dev")
    for part in rel.split("/")[:-1]:
        n = pp.find_type(n, part) if n else None
    after = n.get("props", {}).get(rel.split("/")[-1]) if n else None
    return after

def probe_codes(rel, codes, restore):
    """for each candidate code: write → did the daemon accept it?"""
    for c in codes:
        after = setprop(rel, c)
        accepted = (after == c)
        mark(f"ROUTE {rel} = {c:#010x} accepted={accepted} after={after!r}")
        time.sleep(PAUSE)
    r = setprop(rel, restore)
    mark(f"ROUTE {rel} RESTORED = {restore:#010x} after={r!r}")

# ── 1. the routing sources on hwout2 (Analog Out 1) ──
# playback channel codes: the defaults prove 0x10000000+N = playback ch N
playback = [0x10000006, 0x10000007]            # Playback 7-8 L/R (extensions)
mixer_guesses = []
for t in (0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a):
    mixer_guesses += [t << 24, (t << 24) | 1]  # mixer1 / mixer2 candidates
probe_codes("hwout/hwout2/routeSource", playback + mixer_guesses, 0x10000000)

# ── 2. the HP (hwout1) — its own source space (0x18000026 live) ──
probe_codes("hwout/hwout1/routeSource",
            playback + [0x18000020, 0x18000021, 0x18000022, 0x18000023,
                        0x18000024, 0x18000025, 0x18000027] + mixer_guesses,
            0x18000026)

# ── 3. the pads: all 13 action codes → the 0x49/0x4b enum bytes ──
pad_codes = [0x20002, 0x20003, 0x20004, 0x30002, 0x30003, 0x30004,
             0x40002, 0x40003, 0x40004, 0x5000B, 0x5000C, 0x60001,
             0x70005, 0x70006, 0x70007]
for c in pad_codes:
    after = setprop("appState/actionButtons/Touchpad_A/actionButton", c)
    mark(f"PAD A code={c:#x} accepted={after == c} after={after!r}")
    time.sleep(PAUSE)
r = setprop("appState/actionButtons/Touchpad_A/actionButton", 131076)
mark(f"PAD A RESTORED after={r!r}")

# ── 4. the talkback: the app-scoped path (the helper is gone — does the
#      daemon itself translate it to a vendor write?) ──
for path, v in [("/Apps/Apogee Talkback helper/Talkback/on", 1),
                ("/Apps/Apogee Talkback helper/Talkback/on", 0)]:
    pid = PathIds = pp.hash(path)
    try:
        pp.apply_write(sock, pid, 3, pp.bool_data(v))
        mark(f"TALKBACK {path} = {v} sent")
    except Exception as e:
        mark(f"TALKBACK {path} FAILED: {e}")
    time.sleep(PAUSE)

sock.close()
mark("ROUND2-DONE")
print("round 2 complete")
