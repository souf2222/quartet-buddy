#!/usr/bin/env python3
# sweep_driver.py — drive EVERY Quartet setting through the glue while the
# USB shim captures the wire. Each transition is stamped into
# /tmp/sweep_timeline.txt so frames ↔ settings correlate exactly.
import sys, time, re, struct
sys.path.insert(0, "/Users/soufiane/GitHub/quartet-buddy/tools")
import importlib.util
spec = importlib.util.spec_from_file_location("pp", "/Users/soufiane/GitHub/quartet-buddy/tools/prop_probe.py")
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)

TIMELINE = "/tmp/sweep_timeline.txt"
PAUSE = 2.5   # s between transitions — the daemon's flush cadence

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

def walk(node, path=""):
    """yield (relpath, node) for every node with props"""
    t = node.get("type", "?")
    here = f"{path}/{t}" if path else t
    props = node.get("props", {})
    if isinstance(props, dict) and props:
        yield here, props
    for ch in node.get("children", []):
        yield from walk(ch, here)

# collect every (path, propname, current value)
targets = []
for path, props in walk(dev):
    for name, val in props.items():
        targets.append((path, name, val))

mark(f"PROPERTIES {len(targets)}")
for path, name, val in targets:
    try:
        v = pp.describe_value(val)
    except Exception as e:
        v = f"<{type(val).__name__}: {e}>"
    mark(f"PROP {path}/{name} = {v}")
sock.close()
print("tree dump complete — see /tmp/sweep_timeline.txt")
