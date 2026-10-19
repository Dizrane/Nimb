#!/bin/bash
# Builds build/Nimb.app from the Swift package (ad-hoc signed, no Apple Developer account needed).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.4.1}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Nimb"

make_bundle() {
    local app="build/$1" identifier="$2"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN" "$app/Contents/MacOS/Nimb"
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    cp Resources/AppIconActive.icns "$app/Contents/Resources/AppIconActive.icns"
    cp Resources/world.json "$app/Contents/Resources/world.json"
    cp Resources/telegram.png "$app/Contents/Resources/telegram.png"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Nimb</string>
    <key>CFBundleDisplayName</key><string>Nimb</string>
    <key>CFBundleIdentifier</key><string>${identifier}</string>
    <key>CFBundleExecutable</key><string>Nimb</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

    codesign --force --deep --sign - "$app"
    echo "Built $app"
}

make_bundle Nimb.app com.nimb.app
