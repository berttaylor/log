#!/bin/sh
# ./build.sh           builds build/Log Dev.app, for development
# ./build.sh release   builds build/Log.app and build/Log.dmg, for a release
#
# Both are universal binaries (Apple silicon and Intel). The dev build has its own name and
# bundle id, so it runs next to an installed Log without sharing settings or login items.
set -e
cd "$(dirname "$0")"
VERSION=1.0.1
if [ "$1" = release ]; then NAME=Log ID=work.bertbert.log; else NAME="Log Dev" ID=work.bertbert.log.dev; fi
APP="build/$NAME.app"
rm -rf "$APP" build/Log.dmg && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos15" Log.swift -o "build/Log-$arch"
done
lipo -create build/Log-arm64 build/Log-x86_64 -output "$APP/Contents/MacOS/Log"
rm build/Log-*

# App icon from assets/icon.png
mkdir build/Log.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon.png --out build/Log.iconset/icon_${size}x${size}.png >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon.png --out build/Log.iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns build/Log.iconset -o "$APP/Contents/Resources/Log.icns"
rm -r build/Log.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>Log</string>
<key>CFBundleIconFile</key><string>Log</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Log records your side of the call from the microphone.</string>
</dict></plist>
PLIST

# Ad-hoc signature pinned to the bundle id (not the build hash), so macOS privacy
# permissions survive rebuilds.
codesign --force --sign - -r="designated => identifier \"$ID\"" "$APP"
echo "Built $APP"

[ "$1" = release ] || exit 0
# Disk image: the app, a link to Applications, and the Log icon on the volume.
mkdir build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
cp "$APP/Contents/Resources/Log.icns" build/dmg/.VolumeIcon.icns
hdiutil create -quiet -volname Log -srcfolder build/dmg -format UDRW build/rw.dmg
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint build/mnt build/rw.dmg
SetFile -a C build/mnt
hdiutil detach -quiet build/mnt
hdiutil convert -quiet build/rw.dmg -format UDZO -o build/Log.dmg
rm -r build/dmg build/rw.dmg
echo "Built build/Log.dmg"
