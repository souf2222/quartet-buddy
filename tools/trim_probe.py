#!/usr/bin/env python3
"""Live probe for the tree's hwoutN/trim property (line outs hwout2..7 only —
Main Out/HP have no trim in the tree).

  python3 trim_probe.py read            # all trims
  python3 trim_probe.py set <i> <db>    # write trim, watch echo, re-read, keep
  python3 trim_probe.py test <i> <db>   # write, verify, restore 0.0 afterwards

Writes are double (var-tag 4), id = java31 of /dev/<serial>/hwout/hwout<i>/trim.
"""
import socket, struct, sys, time, zlib, os, importlib.util
sys.path.insert(0, os.path.dirname(__file__))
import jucevt
spec = importlib.util.spec_from_file_location("prop_probe", os.path.join(os.path.dirname(__file__), "prop_probe.py"))
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)
probe = pp.probe


def connect_tree():
    sock, frames = pp.connect_and_hello()
    tree = pp.parse_tree(frames)
    return sock, tree


def dev_serial(tree):
    return pp.find_type(tree, "dev")["type"]


def trim_id(serial, i):
    pid = pp.java31(f"/dev/{serial}/hwout/hwout{i}/trim")
    return pid


def all_trims(tree):
    out = {}
    for t, n in [(f"hwout{i}", pp.find_type(tree, f"hwout{i}")) for i in range(8)]:
        if n:
            out[t] = n["props"].get("trim")
    return out


def write_trim(sock, serial, i, db):
    pid = trim_id(serial, i)
    raw = struct.pack("<d", float(db))
    rec = pp.set_property(pid, 4, raw)
    sock.sendall(probe.juce_wrap(rec))
    print(f"→ setProperty id={pid.hex()} tag=4 (double) value={float(db):+.1f}")
    return pp.watch(sock, 3.0, "write")


def main():
    args = sys.argv[1:]
    sock, tree = connect_tree()
    if tree is None:
        raise SystemExit("no tree — is the Quartet connected?")
    serial = dev_serial(tree)
    print(f"connected · {serial}")

    if not args or args[0] == "read":
        for t, v in all_trims(tree).items():
            print(f"  {t}: trim = {v!r}")
        sock.close()
        return

    idx = int(args[1])
    db = float(args[2])
    before = pp.find_type(tree, f"hwout{idx}")["props"].get("trim") if pp.find_type(tree, f"hwout{idx}") else None
    print(f"BEFORE hwout{idx}.trim = {before!r}")

    echo = write_trim(sock, serial, idx, db)

    tree2 = pp.reread()
    after = pp.find_type(tree2, f"hwout{idx}")["props"].get("trim")
    print(f"AFTER  hwout{idx}.trim = {after!r}")
    applied = (isinstance(after, float) and abs(after - db) < 0.001) or \
              (isinstance(after, int) and abs(after - db) < 0.001)
    print("WRITE ACCEPTED by Glue tree ✓" if applied else "WRITE did not apply ✗")

    if args[0] == "test" and applied:
        print("restoring 0.0 …")
        write_trim(sock, serial, idx, 0.0)
        tree3 = pp.reread()
        fin = pp.find_type(tree3, f"hwout{idx}")["props"].get("trim")
        print(f"RESTORED hwout{idx}.trim = {fin!r}")
    sock.close()


if __name__ == "__main__":
    main()
