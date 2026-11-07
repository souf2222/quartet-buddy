#!/usr/bin/env python3
# sweep_decode.py — correlate the SET/AFTER timeline with the captured USB
# writes: the register map falls out as a table.
import re
from collections import defaultdict

lines = open("/tmp/usbsniff.log").read().splitlines()
writes = []
for i, l in enumerate(lines):
    m = re.match(r"M (\d+) sel=6 .*s1=64 s2=(\d+) s3=(\d+) s4=(\d+) s5=(\d+) ", l)
    if m:
        ts, br, wv, wi, wl = map(int, m.groups())
        pay = ""
        if i + 1 < len(lines) and "m6" in lines[i + 1]:
            pay = lines[i + 1].split(": ")[1][:wl * 2]
        writes.append((ts, br, wv, wi, wl, pay))

sets_ = []
for l in open("/tmp/sweep_timeline.txt"):
    m = re.match(r"([\d.]+)\s+SET (\S+) = (.+?) AFTER=(.+)$", l)
    if m: sets_.append((float(m.group(1)), m.group(2), m.group(3).strip(), m.group(4).strip()))

# dedupe: keep the LAST occurrence of each (rel, value) — later runs are the
# correctly-tagged ones
best = {}
for ts, rel, val, after in sets_:
    best[(rel, val)] = (ts, after)

by_prop = defaultdict(list)
for (rel, val), (ts, after) in best.items():
    win = [w for w in writes if ts - 1.0 <= w[0] <= ts + 2.5]
    by_prop[rel.split("/", 1)[1] if rel.startswith(("hwin", "hwout", "mixers", "appState")) else rel].append(
        (val, after, win))

for prop in sorted(by_prop):
    for val, after, win in by_prop[prop]:
        if not win:
            print(f"{prop:55s} = {val:8s} → (no USB write)")
            continue
        ws = "; ".join(f"{w[1]:#04x} wV={w[2]} wI={w[3]} len={w[4]} ={w[5]}" for w in win)
        print(f"{prop:55s} = {val:8s} → {ws}")
