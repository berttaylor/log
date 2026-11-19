#!/bin/sh
# Builds ~/Applications/Call Log.app (menu bar only, no Dock icon).
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Call Log.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O CallLog.swift -o "$APP/Contents/MacOS/CallLog"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Call Log</string>
<key>CFBundleIdentifier</key><string>work.bertbert.calllog</string>
<key>CFBundleExecutable</key><string>CallLog</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Records your side of the call from the built-in mic.</string>
</dict></plist>
EOF
# Pin the signature to the bundle id (not the build hash) so macOS privacy
# permissions survive rebuilds.
codesign --force --sign - -r='designated => identifier "work.bertbert.calllog"' "$APP"
echo "Built $APP"
