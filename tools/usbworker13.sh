#!/bin/bash
LOG=/tmp/rootworker.log
exec >>"$LOG" 2>&1
echo "=== worker13 (replug-aware) start $(date)"
set -x
rm -f /tmp/usbsniff.log /tmp/apogee_child.log
launchctl bootout system/com.apogeedigital.apogeeglue 2>&1 || true
launchctl bootout system/com.apogeedigital.apogeemessenger 2>&1 || true
pkill -9 -f ApogeeGlue 2>/dev/null
sleep 2
pkill -9 -f ApogeeGlue 2>/dev/null
osascript -e 'display dialog "Unplug the Quartet USB cable now, wait 2 seconds, plug it back in. Click OK after replugging." with title "Quartet capture"' >/dev/null 2>&1 &
echo ">>> waiting for the device to disappear..."
for i in $(seq 1 300); do
  ioreg -p IOUSB -l -w 0 2>/dev/null | grep -q "Quartet@" || { echo "disappeared after ${i}s"; break; }
  sleep 1
done
echo ">>> waiting for it to come back..."
for i in $(seq 1 300); do
  ioreg -p IOUSB -l -w 0 2>/dev/null | grep -q "Quartet@" && { echo "back after ${i}s"; break; }
  sleep 1
done
sleep 6
DYLD_INSERT_LIBRARIES=/tmp/usbsniff.dylib \
  "/Library/Application Support/Apogee/ApogeeGlueDebug.app/Contents/MacOS/ApogeeGlue" >/tmp/apogee_child.log 2>&1 &
DBG_PID=$!
sleep 14
chmod 644 /tmp/usbsniff.log /tmp/apogee_child.log 2>/dev/null
echo "--- vendor request results (kr=0 = working!):"
grep -E "Mdone" /tmp/usbsniff.log | tail -3
cd /Users/soufiane/GitHub/quartet-buddy
echo "--- settling 30s for the identify transient to clear..."
sleep 30
python3 tools/prop_probe.py flag identify 1 >/tmp/probe1.txt 2>&1; sleep 2
python3 tools/prop_probe.py flag identify 1 >>/tmp/probe1.txt 2>&1; sleep 2
python3 tools/prop_probe.py buffer 256 >/tmp/probe2.txt 2>&1; sleep 2
python3 tools/prop_probe.py buffer 128 >/tmp/probe3.txt 2>&1; sleep 2
python3 tools/prop_probe.py reflevel 2 3 >/tmp/probe4.txt 2>&1; sleep 2
python3 tools/prop_probe.py reflevel 2 2 >/tmp/probe5.txt 2>&1; sleep 4
chmod 644 /tmp/usbsniff.log 2>/dev/null
echo "--- frames: $(grep -cE '^[TDWCQRSABM]' /tmp/usbsniff.log)"
kill "$DBG_PID" 2>/dev/null; sleep 2
pkill -9 -f ApogeeGlueDebug 2>/dev/null
sleep 2
launchctl bootstrap system /Library/LaunchDaemons/com.apogeedigital.apogeeglue.plist 2>&1 || true
launchctl bootstrap system /Library/LaunchDaemons/com.apogeedigital.apogeemessenger.plist 2>&1 || true
sleep 3
pgrep -f "ApogeeGlue.app/Contents/MacOS/ApogeeGlue" | head -1
set +x
echo "=== worker13 end $(date)"
