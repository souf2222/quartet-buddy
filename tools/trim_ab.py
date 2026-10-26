#!/usr/bin/env python3
"""Interactive A/B test for the hwoutN/trim property (line outs hwout2..7).

Run:   python3 trim_ab.py [out_index=2] [db=−6] [phase_seconds=3] [cycles=4]
e.g.:  python3 trim_ab.py 2 -6 3 4

Behaviour:
  1. connect + hello, read the tree (serial, baseline trims)
  2. alternate hwout<i>.trim between 0.0 and <db> every <phase_seconds>,
     <cycles> times — writes logged with wall stamps
  3. every type-8 meter frame is decoded (keybyte · serial · 5×00 ·
     L/R float32 per output); per phase it accumulates the PEAK of the two
     channels of output <i> and prints the window's average peak
  4. final state is restored to the baseline trim value

If the firmware applies the trim, the −dB phases should meter lower than
the 0 dB phases — assuming any signal reaches that output pair. If meter
levels stay identical, the trim is tree-only (cosmetic), not DSP.
Meters are compared BEFORE/AFTER each write so we also see whether the
write affected anything at all.
Start THIS script, then press play — it runs autonomously.
"""
import socket, struct, sys, time, zlib, os, importlib.util
sys.path.insert(0, os.path.dirname(__file__))
import jucevt
spec = importlib.util.spec_from_file_location("prop_probe", os.path.join(os.path.dirname(__file__), "prop_probe.py"))
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)
probe = pp.probe


def chunk_frames(buf):
    """Yield complete JUCE frames from a single received buffer (no recv)."""
    while len(buf) >= 8:
        magic, size = struct.unpack("<II", buf[:8])
        if magic != probe.MAGIC:
            buf = buf[1:]
            continue
        if len(buf) < 8 + size:
            break
        yield buf[8:8 + size]
        buf = buf[8 + size:]


def set_trim(sock, serial, i, db):
    pid = pp.java31(f"/dev/{serial}/hwout/hwout{i}/trim")
    sock.sendall(probe.juce_wrap(pp.set_property(pid, 4, struct.pack("<d", float(db)))))
    return pid


def meters_during(sock, seconds, out_index, label):
    """collect type-8 frames for `seconds`; return dict with peak stats."""
    sock.settimeout(0.4)
    pair = []
    allout = {}
    n_floats = None
    end = time.time() + seconds
    carry = b""
    while time.time() < end:
        try:
            d = sock.recv(65536)
            if d:
                carry = d          # meter frames are small; a recv holds many
        except socket.timeout:
            continue
        for fr in chunk_frames(carry):
            if (fr[0] & 0x1F) != 8:
                continue
            sl = {0: 1, 0x40: 2, 0x80: 4}[fr[0] & 0xC0]
            size = int.from_bytes(fr[1:1 + sl], "little")
            data = fr[1 + sl + 1:1 + sl + 1 + size]
            # data: serial string (NUL-term) then 5×00 pad then float pairs
            nul = data.find(b"\x00")
            if nul < 0:
                continue
            if data[nul + 1:nul + 6] != b"\x00\x00\x00\x00\x00":
                continue                    # not the expected pad — skip
            body = data[nul + 6:]
            n = len(body) // 4
            if not n:
                continue
            if n_floats is None and n:
                n_floats = n
            if n == n_floats or n_floats is None:
                vals = list(struct.unpack("<" + "f" * n, body[:n * 4])) if n else []
                # L/R per output — output i = floats [2i, 2i+1]
                pair.append(max(abs(vals[2 * out_index]), abs(vals[2 * out_index + 1]))
                            if 2 * out_index + 1 <= len(vals) else 0.0)
                for oi in range(len(vals) // 2):
                    allout[oi] = max(allout.get(oi, 0.0),
                                     abs(vals[2 * oi]), abs(vals[2 * oi + 1] if 2 * oi + 1 < len(vals) else 0.0))
    peak = max(pair) if pair else None
    info = f"frames={len(pair)} floats/frame={n_floats}"
    return {"avg_peak": (sum(pair) / len(pair)) if pair else None,
            "peak": peak, "info": info, "samples": len(pair),
            "all": allout}


def main():
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    db = float(sys.argv[2]) if len(sys.argv) > 2 else -6.0
    phase = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
    cycles = int(sys.argv[4]) if len(sys.argv) > 4 else 4

    sock, tree = pp.connect_and_hello()
    tree = pp.parse_tree(tree)
    if tree is None:
        raise SystemExit("no tree — is the unit connected?")
    serial = pp.find_type(tree, "dev")["type"]
    base = pp.find_type(tree, f"hwout{idx}")["props"].get("trim") if pp.find_type(tree, f"hwout{idx}") else None
    print(f"A/B trim test · {serial} · hwout{idx} · flip {db:+.1f} ↔ 0.0 dB · "
          f"{phase:.0f}s × {cycles} cycles · baseline trim={base!r}")
    print("PRESS PLAY NOW — measuring meter of output pair…")

    pid = set_trim(sock, serial, idx, 0.0)      # always start at unity
    time.sleep(0.3)
    shown = [False]

    try:
        for c in range(cycles):
            for val in (db, 0.0):
                set_trim(sock, serial, idx, val)   # flip FIRST …
                time.sleep(0.2)                    # let the firmware pick it up
                lab = f"{val:+.1f} dB"
                win = meters_during(sock, phase, idx, lab)   # … then measure
                print(f"cycle {c + 1}/{cycles} phase {lab:>7}: "
                      f"avg_peak={win['avg_peak']!r:>10} peak={win['peak']!r:>10} "
                      f"({win['info']})")
                if not shown[0]:
                    shown[0] = True
                    print("  meter map of ALL outputs (peak per pair):")
                    for oi in sorted(win["all"]):
                        print(f"    hwout{oi}: {win['all'][oi]:.3f}")
        # restore: baseline value if it was nonzero, else 0.0
        restore = float(base) if isinstance(base, (int, float)) else 0.0
        set_trim(sock, serial, idx, restore)
        print(f"restored hwout{idx}.trim = {restore:+.1f}")
    finally:
        tree2 = pp.reread()
        after = pp.find_type(tree2, f"hwout{idx}") if pp.find_type(tree2, f"hwout{idx}") else None
        print(f"CLOSED (ID {pid.hex()}) final tree hwout{idx}.trim = "
              f"{after['props'].get('trim') if after else None!r}")
        sock.close()
        if base not in (0, 0.0, None) and abs((base if isinstance(base, (int, float)) else 0)) > 1e-9:
            print(f"NOTE baseline was {base!r} — re-run trim_probe set to restore it")


if __name__ == "__main__":
    main()
