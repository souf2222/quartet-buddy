#!/bin/bash
# Builds QuartetBuddy.app (menubar companion for the Apogee Quartet).
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="QuartetBuddy"
BUNDLE="build/$APPNAME.app"
SRC="Sources"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>QuartetBuddy</string>
    <key>CFBundleIdentifier</key>
    <string>com.quartetbuddy.app</string>
    <key>CFBundleName</key>
    <string>Quartet Buddy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "compiling..."
swiftc -O \
    "$SRC/main.swift" \
    "$SRC/AppDelegate.swift" \
    "$SRC/GlueProtocol.swift" \
    "$SRC/GlueClient.swift" \
    "$SRC/MediaKeyTap.swift" \
    "$SRC/DefaultDeviceMonitor.swift" \
    "$SRC/HotKey.swift" \
    "$SRC/HotKeyRecorder.swift" \
    "$SRC/MidiWatcher.swift" \
    -framework AppKit -framework CoreAudio -framework CoreMIDI \
    -framework Carbon -framework Foundation \
    -o "$BUNDLE/Contents/MacOS/$APPNAME"

codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "built: $BUNDLE"
echo "first run: $BUNDLE/Contents/MacOS/$APPNAME  (grant Input Monitoring when prompted)"
