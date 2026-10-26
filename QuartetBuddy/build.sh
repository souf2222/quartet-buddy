#!/bin/bash
# Builds "Quartet Buddy.app", signs it, and restarts the running app so the
# new build goes live immediately.
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="Quartet Buddy"
BUNDLE="build/$APPNAME.app"
SRC="Sources"

echo "building…"
rm -rf "$BUNDLE" "build/QuartetBuddy.app"   # also remove the legacy pre-rename bundle
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# bundle the icons (menubar Apogee logo + the control window's flaticon
# glyphs: speaker, headphones, microphone-black-shape, mute, unmute)
cp assets/*.png "$BUNDLE/Contents/Resources/" 2>/dev/null || true

cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Quartet Buddy</string>
    <key>CFBundleIdentifier</key>
    <string>com.quartetbuddy.app</string>
    <key>CFBundleName</key>
    <string>Quartet Buddy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Quartet Buddy captures the system audio bound for the Quartet to run your chosen AU plugin (e.g. room correction) on its outputs. Nothing is recorded or stored; audio is processed locally in real time.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Auto Gain and the ADAT Gain Assistant listen briefly to the selected inputs while they measure levels (and, for Auto Gain, calibrate the preamp). The audio is analyzed in real time and never recorded or stored.</string>
</dict>
</plist>
PLIST

swiftc -O \
    "$SRC/main.swift" \
    "$SRC/AppDelegate.swift" \
    "$SRC/GlueProtocol.swift" \
    "$SRC/GlueClient.swift" \
    "$SRC/PathIdSetup.swift" \
    "$SRC/DefaultDeviceMonitor.swift" \
    "$SRC/HotKey.swift" \
    "$SRC/HotKeyRecorder.swift" \
    "$SRC/Shortcuts.swift" \
    "$SRC/MidiWatcher.swift" \
    "$SRC/QBLog.swift" \
    "$SRC/AutoGain.swift" \
    "$SRC/AdatGain.swift" \
    "$SRC/LogoIcon.swift" \
    "$SRC/QuartetPresence.swift" \
    "$SRC/OSVolumeMirror.swift" \
    "$SRC/InsertServer.swift" \
    "$SRC/QuartetWindow.swift" \
    "$SRC/QuartetControlWindow.swift" \
    "$SRC/QuickControlPanel.swift" \
    "$SRC/SettingsUI.swift" \
    "$SRC/SettingsWindow.swift" \
    -framework AppKit -framework CoreAudio -framework CoreMIDI \
    -framework Carbon -framework Foundation -framework IOKit \
    -o "$BUNDLE/Contents/MacOS/$APPNAME"

# Sign with the stable identity when available so the Input Monitoring grant
# and the login-item registration survive rebuilds; otherwise ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(QuartetBuddy Developer\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$BUNDLE" 2>/dev/null; then
    echo "signed with identity: $IDENTITY"
else
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
    echo "signed ad-hoc (rebuilds will require re-granting Input Monitoring)"
fi

# Restart: kill any running instance and launch the fresh build,
# so compiling immediately puts the new code in the menubar.
if pgrep -f "Quartet Buddy.app" >/dev/null 2>&1 || pgrep -x "$APPNAME" >/dev/null 2>&1; then
    echo "restarting running app…"
    pkill -f "Quartet Buddy.app" 2>/dev/null || true
    sleep 1
fi
pkill -x "QuartetBuddy" 2>/dev/null || true   # legacy name (pre-rename)
open "$BUNDLE"

echo "built + running: $BUNDLE"
