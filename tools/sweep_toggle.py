#!/usr/bin/env python3
# sweep_toggle.py — toggle every un-decoded property A→B→A while the shim
# captures the USB wire. Every transition is stamped in the timeline.
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

def val_data(v):
    # the tree's var-tags: 1=int32, 3=bool, 4=DOUBLE (64-bit!) — the probe's
    # guessed tag 2 (32-bit float) was silently ignored by the daemon
    if isinstance(v, bool): return 3, pp.bool_data(v)
    if isinstance(v, int): return 1, pp.int_data(v)
    if isinstance(v, float): return 4, struct.pack("<d", v)
    return 5, pp.string_data(str(v))

sock, frames = pp.connect_and_hello()
tree = pp.parse_tree(frames)
dev = pp.find_type(tree, "dev")
serial = dev["type"]
mark(f"SERIAL {serial}")

TOUCH = [
    "hwin/hwin0/softLimit", "hwin/hwin0/polarityInvert", "hwin/hwin0/group",
    "hwin/hwin0/micSettings/PreModelQuartet/gain",
    "hwin/hwin0/instSettings/PreModelQuartet/gain",
    "hwin/hwin0/micSettings/phantom", "hwin/hwin0/analogRefLevel",
    "peakHold", "overHold", "lockHomeScreen", "keyboardVolumeControls",
    "hwout/hwout0/dim", "hwout/hwout0/sum", "hwout/hwout1/dim", "hwout/hwout1/sum",
    "hwout/hwout2/analogRefLevel", "hwout/hwout4/trim", "hwout/hwout2/trim",
    "hwout/hwout0/mainOutputFormat", "hwout/hwout0/activeSpeakerSet",
    "mixers/mixer0/channels/channel0/pan", "mixers/mixer0/channels/channel0/solo",
    "mixers/mixer0/channels/channel0/volume", "mixers/mixer0/channels/channel0/mute",
    "mixers/mixer0/channels/master/volume", "mixers/mixer0/channels/master/mute",
    "appState/actionButtons/Touchpad_A/actionButton",
    "appState/actionButtons/Encoder_Push/actionButton",
]
ORIG = {}
def node_for(rel):
    n = dev
    for part in rel.split("/")[:-1]:
        n = pp.find_type(n, part)
        if n is None: return None, None
    return n, rel.split("/")[-1]
for rel in TOUCH:
    n, leaf = node_for(rel)
    if n is not None:
        ORIG[rel] = n.get("props", {}).get(leaf)

def restore_all():
    mark("RESTORE-START")
    for rel, v in ORIG.items():
        if v is None: continue
        try:
            setter(rel, v)
        except Exception as e:
            mark(f"RESTORE-FAIL {rel}: {e}")
    mark("RESTORE-DONE")

def setter(rel, v):
    tag, data = val_data(v)
    pid = pp.dev_path(serial, rel)
    pp.apply_write(sock, pid, tag, data)
    time.sleep(0.8)
    tree2 = pp.reread()
    node = pp.find_type(tree2, "dev")
    parts = rel.split("/")
    for part in parts[:-1]:
        node = pp.find_type(node, part) if node else None
    after = node.get("props", {}).get(parts[-1]) if node else None
    mark(f"SET {rel} = {v!r} AFTER={pp.describe_value(after) if after is not None else '?'}")

def toggle(rel, b_val, a_val):
    """A→B→A with stamps"""
    setter(rel, b_val); time.sleep(PAUSE)
    setter(rel, a_val); time.sleep(PAUSE)

# ── the input-side unknowns (hwin0 = input 1) ──
toggle("hwin/hwin0/softLimit", False, True)          # expect 0x11
toggle("hwin/hwin0/polarityInvert", True, False)     # expect 0x44/0x3e-family
toggle("hwin/hwin0/group", True, False)              # the ganging bit
toggle("hwin/hwin0/micSettings/PreModelQuartet/gain", 30.0, 0.0)   # verify 0x34
toggle("hwin/hwin0/instSettings/PreModelQuartet/gain", 12.0, 0.0)  # verify 0x3e
toggle("hwin/hwin0/micSettings/phantom", True, False)              # verify 0x15
toggle("hwin/hwin0/analogRefLevel", 2, 1)             # verify 0x16

# ── the device flags ──
toggle("peakHold", 0, 1)
toggle("overHold", 0, 1)
toggle("lockHomeScreen", False, True)
toggle("keyboardVolumeControls", 1, 0)

# ── the output-side unknowns (hwout0 = Main) ──
toggle("hwout/hwout0/dim", True, False)               # verify 0x4F?
toggle("hwout/hwout0/sum", True, False)               # verify 0x4E?
toggle("hwout/hwout1/dim", True, False)
toggle("hwout/hwout1/sum", True, False)

# ── the analog outs: ref levels + trims (hwout2 = Analog Out 1) ──
toggle("hwout/hwout2/analogRefLevel", 3, 2)           # +4 → −10 → +4
toggle("hwout/hwout4/trim", -10.0, -20.0)             # trim wiggle (was −20)
toggle("hwout/hwout4/trim", 0.0, -20.0)               # and a 0 pass (restore −20)
toggle("hwout/hwout2/trim", -5.0, 0.0)                # trim wiggle (was 0)

# ── the monitor format / speaker set ──
toggle("hwout/hwout0/mainOutputFormat", 0, 2)
toggle("hwout/hwout0/activeSpeakerSet", 0, 1)

# ── the mixer: pan, solo, master, volume, mute (channel0 of mixer0) ──
toggle("mixers/mixer0/channels/channel0/pan", 0.25, 0.5)     # the PAN register!
toggle("mixers/mixer0/channels/channel0/solo", True, False)  # the SOLO register!
toggle("mixers/mixer0/channels/channel0/volume", -10.0, 0.0) # verify 0x4C
toggle("mixers/mixer0/channels/channel0/mute", True, False)  # verify 0x4E
toggle("mixers/mixer0/channels/master/volume", -6.0, 0.0)
toggle("mixers/mixer0/channels/master/mute", 1.0, 0.0)

# ── the pads (the action codes) ──
toggle("appState/actionButtons/Touchpad_A/actionButton", 262147, 131076)
toggle("appState/actionButtons/Encoder_Push/actionButton", 262147, 327691)

sock.close()
sock2, frames2 = pp.connect_and_hello()
sock = sock2
tree = pp.parse_tree(frames2)
dev = pp.find_type(tree, "dev")
try:
    restore_all()
finally:
    sock.close()
mark("SWEEP-DONE")
print("sweep complete")
