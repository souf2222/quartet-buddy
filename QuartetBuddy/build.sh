#!/bin/bash
# Builds QuartetBuddy.app (menubar companion for the Apogee Quartet).
set -euo pipefail
cd "$(dirname "$0")"

APPNAME="QuartetBuddy"
BUNDLE="build/$APPNAME.app"
SRC="Sources"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# bundle the Apogee logo for the menubar icon / HUD
cp assets/apogee-icon-small.png "$BUNDLE/Contents/Resources/" 2>/dev/null || true
cp assets/apogee-icon.png "$BUNDLE/Contents/Resources/" 2>/dev/null || true

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
    "$SRC/InputMonitoring.swift" \
    "$SRC/LogoIcon.swift" \
    -framework AppKit -framework CoreAudio -framework CoreMIDI \
    -framework Carbon -framework Foundation -framework IOKit \
    -o "$BUNDLE/Contents/MacOS/$APPNAME"

# Sign with the stable identity when available so the Input Monitoring
# grant survives rebuilds; otherwise fall back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(QuartetBuddy Developer\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$BUNDLE" 2>/dev/null; then
    echo "signed with identity: $IDENTITY"
else
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
    echo "signed ad-hoc (rebuilds will require re-granting Input Monitoring)"
fi

echo "built: $BUNDLE"
echo "first run: $BUNDLE/Contents/MacOS/$APPNAME  (grant Input Monitoring when prompted)"
