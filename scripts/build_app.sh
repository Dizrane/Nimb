#!/bin/bash
# Builds build/Nimb.app from the Swift package (ad-hoc signed, no Apple Developer account needed).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.9.20}"

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
    cp Resources/notification.mp3 "$app/Contents/Resources/notification.mp3"
    cp Resources/nimb-tunnel.sh "$app/Contents/Resources/nimb-tunnel.sh"
    cp Resources/warp-preset.conf "$app/Contents/Resources/warp-preset.conf"
    # The pictures of the interface (art-studio/deliver): only what the app draws, not the sources and the masters.
    for art in halo hood paper-plane media-scene header icon-ai icon-telegram icon-media icon-welcome icon-gear; do
        mkdir -p "$app/Contents/Resources/Art/$art"
        cp art-studio/deliver/$art/*.png "$app/Contents/Resources/Art/$art/"
    done
    if [ -f Resources/amneziawg-go ]; then
        cp Resources/amneziawg-go "$app/Contents/Resources/amneziawg-go"
    else
        echo "Warning: Resources/amneziawg-go is missing, the WARP tunnel will be unavailable (run scripts/build_awg.sh)" >&2
    fi

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

    # iCloud Drive and Finder add attributes to folders of a bundle that sits on the Desktop, and codesign refuses a bundle that
    # has them: clear them right before signing and try again if they came back in between.
    for attempt in 1 2 3; do
        xattr -cr "$app" 2>/dev/null || true
        if codesign --force --deep --sign - "$app"; then break; fi
        [ "$attempt" = 3 ] && { echo "codesign failed" >&2; exit 1; }
        sleep 1
    done
    echo "Built $app"
}

make_bundle Nimb.app com.nimb.app
