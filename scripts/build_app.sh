#!/bin/bash
# Builds build/Nimb.app or, with --test, build/NimbTest.app from the same Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.9.27}"
NAME=Nimb
IDENTIFIER=com.nimb.app
ICON='<key>CFBundleIconFile</key><string>AppIcon</string>'
DESCRIPTION=''
IS_TEST=false
case "${1:-}" in
    --test) IS_TEST=true ;;
    '') ;;
    *) echo 'Usage: scripts/build_app.sh [--test]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Usage: scripts/build_app.sh [--test]' >&2; exit 2; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nimb-app.XXXXXXXX")
KEY_SOURCE=''
cleanup() {
    if [ -n "$KEY_SOURCE" ]; then rm -f "$KEY_SOURCE"; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
OFFICIAL=()
PACKAGE="$PWD"
if $IS_TEST; then
    NAME=NimbTest
    IDENTIFIER=com.nimb.test
    ICON=''
    DESCRIPTION='<key>NSHumanReadableCopyright</key><string>Тестовая модификация на основе Nimb</string>'
    # A release build may be generating its signing source concurrently. Copy the package without that file.
    PACKAGE="$WORK/source"
    mkdir -p "$PACKAGE/Sources"
    cp Package.swift "$PACKAGE/"
    cp -R Tests "$PACKAGE/"
    rsync -a --exclude '/Nimb/Report/ReportKey.official.swift' Sources/ "$PACKAGE/Sources/"
    diff -qr -x ReportKey.official.swift Sources "$PACKAGE/Sources"
else
    # The temporary source contains the report key for this version only. Source builds without it send no reports.
    REPORT_KEY_FILE="$HOME/.config/nimb/report.key"
    KEY_SOURCE=Sources/Nimb/Report/ReportKey.official.swift
    rm -f "$KEY_SOURCE"
    if [ -f "$REPORT_KEY_FILE" ]; then
        python3 scripts/report_key.py source "$REPORT_KEY_FILE" "$VERSION" "$KEY_SOURCE"
        OFFICIAL=(-Xswiftc -DOFFICIAL_BUILD)
    else
        echo "Note: no release report key: this build is not an official one and sends no reports." >&2
    fi
fi

BUILD_ARGS=(--package-path "$PACKAGE" -c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" ${OFFICIAL[@]+"${OFFICIAL[@]}"}
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Nimb"

make_bundle() {
    local app="$WORK/$NAME.app" destination="build/$NAME.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN" "$app/Contents/MacOS/$NAME"
    if ! $IS_TEST; then cp Resources/AppIcon.icns Resources/AppIconActive.icns "$app/Contents/Resources/"; fi
    cp LICENSE THIRD-PARTY-NOTICES.md "$app/Contents/Resources/"
    cp Resources/{world.json,telegram.png,nimb-tunnel.sh,warp-preset.conf} "$app/Contents/Resources/"
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
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${IDENTIFIER}</string>
    <key>CFBundleExecutable</key><string>${NAME}</string>
    ${ICON}
    ${DESCRIPTION}
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

    # Sign outside the checkout, where Finder can attach attributes that codesign rejects.
    xattr -cr "$app"
    codesign --force --deep --sign - "$app"
    codesign --verify --deep --strict "$app"
    mkdir -p build
    if [ -e "$destination" ]; then mv "$destination" "$WORK/previous.app"; fi
    if ! mv "$app" "$destination"; then
        if [ -e "$WORK/previous.app" ]; then mv "$WORK/previous.app" "$destination"; fi
        return 1
    fi
    echo "Built $destination"
}

make_bundle
