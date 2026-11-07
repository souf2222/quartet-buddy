# usbhooks.py — steerable frame-capture hooks for ApogeeGlue
import lldb, time, os
LOG = "/tmp/usb_frames.log"
CMD = "/tmp/hook_cmd.txt"
SENDER_OFF = 0x188798   # sendWithRetry(messenger, cmdId, payload, len, lo, hi)
WRITE_OFF  = 0x36C70    # sync WritePipeTO helper
READ_OFF   = 0x36B44    # sync ReadPipe helper
_pending_read = {}
_state = dict(target=None, load0=0, bps={})

def _w(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")

def _dump_mem(process, addr, size):
    if size <= 0 or size > 4096:
        return f"<size {size}>"
    err = lldb.SBError()
    data = process.ReadMemory(addr, size, err)
    if not err.Success():
        return f"<unreadable @0x{addr:x}>"
    return data.hex()

def _reg(frame, idx):
    return frame.FindRegister(f"x{idx}").GetValueAsUnsigned()

def _regs(frame, n=6):
    return " ".join(f"x{i}={_reg(frame,i):#x}" for i in range(n))

def cb_generic(frame, bp_loc, _dict):
    name = bp_loc.GetBreakpoint().GetID()
    tag = _state["bps"].get(name, f"bp{name}")
    process = frame.GetThread().GetProcess()
    line = f"B {time.time():.6f} {tag} {_regs(frame)}"
    # best-effort buffer dumps: x1 as u32, x2/x3 as ptrs
    for ri in (1, 2, 3):
        v = _reg(frame, ri)
        if 0x100000000 <= v < 0x800000000:
            line += f" m{xri(ri)}={_dump_mem(process, v, 64)}"
    _w(line)
    return False

def xri(i):
    return f"x{i}"

def cb_tx(frame, bp_loc, _dict):
    process = frame.GetThread().GetProcess()
    _w(f"T {time.time():.6f} pipe={_reg(frame,1)} len={_reg(frame,3)} data={_dump_mem(process,_reg(frame,2),_reg(frame,3))}")
    return False

def cb_rx_pre(frame, bp_loc, _dict):
    _pending_read[frame.GetThread().GetIndexID()] = (_reg(frame,2), _reg(frame,3))
    return False

def cb_rx_post(frame, bp_loc, _dict):
    process = frame.GetThread().GetProcess()
    info = _pending_read.pop(frame.GetThread().GetIndexID(), None)
    if info:
        buf, lenptr = info
        err = lldb.SBError()
        raw = process.ReadMemory(lenptr, 4, err)
        ln = int.from_bytes(raw, "little") if err.Success() else -1
        _w(f"R {time.time():.6f} len={ln} data={_dump_mem(process, buf, ln)}")
    return False

def _add_bp(target, off, cbname, tag):
    bp = target.BreakpointCreateByAddress(_state["load0"] + off)
    bp.SetScriptCallbackBody(f"import usbhooks; return usbhooks.{cbname}(frame, bp_loc, dict)")
    _state["bps"][bp.GetID()] = tag
    _w(f"H add {tag} @{off:#x} sites={bp.GetNumLocations()}")

def _exec_cmd(line):
    parts = line.split()
    target = _state["target"]
    if parts[0] == "bp" and len(parts) >= 2:
        off = int(parts[1], 0)
        cb = parts[2] if len(parts) > 2 else "cb_generic"
        tag = parts[3] if len(parts) > 3 else f"off_{off:#x}"
        _add_bp(target, off, cb, tag)
    elif parts[0] == "done":
        try: target.process.Detach()
        except Exception: pass
        _w("H cmd done → detach")
        os._exit(0)

def usbhooks_setup(debugger, command, exe_ctx, result, _dict):
    target = debugger.GetSelectedTarget()
    _state["target"] = target
    m = None
    for mod in target.module_iter():
        if "ApogeeGlue" in str(mod.GetFileSpec().basename):
            m = mod
            break
    if m is None:
        result.AppendMessage("!! module not found"); return
    ENTRY_OFF = 0x30CF4
    pc = target.process.GetThreadAtIndex(0).GetFrameAtIndex(0).GetPC()
    slide = pc - (0x100000000 + ENTRY_OFF)
    _state["load0"] = slide + 0x100000000
    result.AppendMessage(f"pc={pc:#x} slide={slide:#x}")
    _w(f"H {time.time():.6f} pc={pc:#x} slide={slide:#x}")
    _add_bp(target, SENDER_OFF, "cb_generic", "sender")
    _add_bp(target, WRITE_OFF, "cb_tx", "writeTO")
    _add_bp(target, READ_OFF, "cb_rx_pre", "read_pre")
    import threading
    def watchdog():
        deadline = time.time() + 1500
        while time.time() < deadline:
            if os.path.exists(CMD):
                try:
                    with open(CMD) as f:
                        lines = [l.strip() for l in f if l.strip()]
                    os.remove(CMD)
                    for l in lines:
                        _exec_cmd(l)
                except Exception as e:
                    _w(f"H cmd error {e}")
            if os.path.exists("/tmp/capture_done"):
                break
            time.sleep(1)
        try: target.process.Detach()
        except Exception: pass
        _w(f"H {time.time():.6f} watchdog detach")
        os._exit(0)
    threading.Thread(target=watchdog, daemon=True).start()

def __lldb_init_module(debugger, _dict):
    debugger.HandleCommand("command script add -f usbhooks.usbhooks_setup usbhooks_setup")
