#!/bin/bash
# Builds build/RDNS.app (shown as "Nimb"; the file and bundle id keep their old names so that 0.1.x can still update itself)
# from the Swift package (ad-hoc signed, no Apple Developer account needed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/RDNS.app"
VERSION="${VERSION:-0.2.1}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/RDNS"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RDNS"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/AppIconActive.icns "$APP/Contents/Resources/AppIconActive.icns"
cp Resources/world.json "$APP/Contents/Resources/world.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nimb</string>
    <key>CFBundleDisplayName</key><string>Nimb</string>
    <key>CFBundleIdentifier</key><string>com.rdns.app</string>
    <key>CFBundleExecutable</key><string>RDNS</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
