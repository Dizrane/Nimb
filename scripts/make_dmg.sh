#!/bin/bash
# Builds build/Nimb-<version>.dmg from build/Nimb.app: a disk image with the app and a shortcut to «Программы»,
# so that installing is dragging one icon onto the other. Run scripts/build_app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Nimb.app"
[ -d "$APP" ] || { echo "Нет $APP: сначала scripts/build_app.sh" >&2; exit 1; }
VERSION="$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)"
DMG="build/Nimb-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap '[ -n "$STAGE" ] && rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/Nimb.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# hdiutil is the one tool that exists on every macOS Nimb runs on; newer systems only warn that it is deprecated.
OUT="$(hdiutil create -volname "Nimb" -srcfolder "$STAGE" -format UDZO -ov "$DMG" 2>&1)" || { echo "$OUT" >&2; exit 1; }
echo "Built $DMG"
