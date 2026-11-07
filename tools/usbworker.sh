#!/bin/bash
LOG=/tmp/rootworker.log
exec >>"$LOG" 2>&1
echo "=== worker12 (airtight) start $(date)"
set -x
rm -f /tmp/usbsniff.log /tmp/apogee_child.log
# stop BOTH apogee jobs + any strays
launchctl bootout system/com.apogeedigital.apogeeglue 2>&1 || true
launchctl bootout system/com.apogeedigital.apogeemessenger 2>&1 || true
pkill -9 -f ApogeeGlue 2>/dev/null
sleep 3
for i in $(seq 1 25); do
  pgrep -f ApogeeGlue >/dev/null || break
  pkill -9 -f ApogeeGlue 2>/dev/null
  sleep 1
done
echo "--- ApogeeGlue procs left: $(pgrep -f ApogeeGlue | wc -l | tr -d ' ')"
# wait until the Quartet has NO exclusive owner
for i in $(seq 1 20); do
  ioreg -p IOUSB -l -w 0 2>/dev/null | grep -q 'UsbExclusiveOwner.*ApogeeGlue' || { echo "device free"; break; }
  sleep 1
done
# launch the debug daemon with the shim
DYLD_INSERT_LIBRARIES=/tmp/usbsniff.dylib DYLD_FORCE_FLAT_NAMESPACE=1 \
  "/Library/Application Support/Apogee/ApogeeGlueDebug.app/Contents/MacOS/ApogeeGlue" >/tmp/apogee_child.log 2>&1 &
DBG_PID=$!
sleep 12
chmod 644 /tmp/usbsniff.log /tmp/apogee_child.log 2>/dev/null
echo "--- debug daemon $DBG_PID alive: $(kill -0 $DBG_PID 2>/dev/null && echo YES || echo NO)"
echo "--- shim:"; grep -E "learned|hooked|OPEN" /tmp/usbsniff.log | head -8
echo "--- device owner:"; ioreg -p IOUSB -l -w 0 2>/dev/null | grep -o 'UsbExclusiveOwner.*ApogeeGlue' | head -1
cd /Users/soufiane/GitHub/quartet-buddy
python3 tools/prop_probe.py flag identify 1 >/tmp/probe1.txt 2>&1; sleep 2
python3 tools/prop_probe.py buffer 256 >/tmp/probe2.txt 2>&1; sleep 2
python3 tools/prop_probe.py buffer 128 >/tmp/probe3.txt 2>&1; sleep 2
python3 tools/prop_probe.py reflevel 2 3 >/tmp/probe4.txt 2>&1; sleep 2
python3 tools/prop_probe.py reflevel 2 2 >/tmp/probe5.txt 2>&1; sleep 4
chmod 644 /tmp/usbsniff.log 2>/dev/null
echo "--- frames: $(grep -cE '^[TDWCQR]' /tmp/usbsniff.log)"
kill "$DBG_PID" 2>/dev/null; sleep 2
pkill -9 -f ApogeeGlueDebug 2>/dev/null
sleep 2
launchctl bootstrap system /Library/LaunchDaemons/com.apogeedigital.apogeeglue.plist 2>&1 || true
launchctl bootstrap system /Library/LaunchDaemons/com.apogeedigital.apogeemessenger.plist 2>&1 || true
sleep 3
pgrep -f "ApogeeGlue.app/Contents/MacOS/ApogeeGlue" | head -1
set +x
echo "=== worker12 end $(date)"
