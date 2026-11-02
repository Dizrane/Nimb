#!/bin/bash
# Builds the installers of Nimb for Windows on a Mac: ./build.sh [arm64] [amd64]  (both by default).
# Needs: go, the wails CLI (go install github.com/wailsapp/wails/v2/cmd/wails@v2.17.0), makensis (brew install nsis).
# The result is in build/windows/ at the root of the repository (it is not stored in git): Nimb-Setup-<version>-<arch>.exe, its .sig (when the
# signing key is there) and SHA256.txt.
set -euo pipefail
export LC_ALL=en_US.UTF-8                     # makensis of Homebrew dies in the plain C locale (std::bad_alloc)
cd "$(dirname "$0")/.."                      # windows/
ROOT="$(cd .. && pwd)"
VERSION=$(sed -n 's/.*Version = "\(.*\)".*/\1/p' internal/version/version.go)
WAILS="$(go env GOPATH)/bin/wails"
OUT="$ROOT/build/windows"
CACHE="$ROOT/build/windows-cache"
mkdir -p "$OUT" "$CACHE"
REPORT_KEY_FILE="${REPORT_KEY_FILE:-$HOME/.config/nimb/report.key}"
ARCHES=("$@"); [ ${#ARCHES[@]} -eq 0 ] && ARCHES=(arm64 amd64)
UNKEYED=""

# wintun.dll of the Wintun project, taken from its own site and checked against the sum that was looked at by hand.
WINTUN_ZIP_SHA=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
if [ ! -f "$CACHE/wintun.zip" ]; then curl -fsSL -o "$CACHE/wintun.zip" https://www.wintun.net/builds/wintun-0.14.1.zip; fi
[ "$(shasum -a 256 "$CACHE/wintun.zip" | cut -d' ' -f1)" = "$WINTUN_ZIP_SHA" ] || { echo "wintun.zip has another sum, stop" >&2; exit 1; }
[ -d "$CACHE/wintun" ] || unzip -q -o "$CACHE/wintun.zip" -d "$CACHE"

for ARCH in "${ARCHES[@]}"; do
  echo "== $ARCH"
  STAGE="$OUT/stage-$ARCH"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  GOOS=windows GOARCH=$ARCH go build -trimpath -ldflags "-s -w" -o "$STAGE/nimb-svc.exe" ./cmd/nimb-svc
  cp "$CACHE/wintun/bin/$ARCH/wintun.dll" "$STAGE/wintun.dll"
  # The key that signs reports (see internal/report/sign.go) is kept outside the repository. With it the build is an official one; without
  # it (a build from the sources) the program sends no reports and says «MOD». The key is made for this version and mixed with its number,
  # and goes to the linker only. The program also learns the sums of the files that the service is made of (what stands next to it on a
  # computer must be these), so that a replaced service or wintun.dll makes the build «not ours».
  LDFLAGS="-s -w"; KEYED=no
  if [ -f "$REPORT_KEY_FILE" ]; then
    MIXED=$(go run ./tools/reportkey mixed "$REPORT_KEY_FILE" "$VERSION")
    FILES="nimb-svc.exe=$(shasum -a 256 "$STAGE/nimb-svc.exe" | cut -d' ' -f1);wintun.dll=$(shasum -a 256 "$STAGE/wintun.dll" | cut -d' ' -f1)"
    LDFLAGS="$LDFLAGS -X main.officialReportKey=$MIXED -X main.officialFiles=$FILES"; KEYED=yes
  else
    echo "Note: no $REPORT_KEY_FILE: this build is not an official one and sends no reports." >&2
  fi
  (cd cmd/nimb && "$WAILS" build -platform "windows/$ARCH" -s -skipbindings -trimpath -ldflags "$LDFLAGS" -o Nimb.exe >/dev/null && cp build/bin/Nimb.exe "$STAGE/Nimb.exe")
  # What is in the finished Nimb.exe: the strings given to the linker (-X) stand in the file as they are, so the key and the sums can be looked
  # for. The sums must be those of the very files that go into the installer, or the program would call its own build «not ours».
  if [ "$KEYED" = yes ]; then
    grep -aqF "$MIXED" "$STAGE/Nimb.exe" && grep -aqF "$FILES" "$STAGE/Nimb.exe" || { echo "STOP: Nimb.exe ($ARCH) has no key or no right sums of nimb-svc.exe / wintun.dll inside" >&2; exit 1; }
  else
    UNKEYED="$UNKEYED $ARCH"
  fi
  cp "$ROOT/LICENSE" "$STAGE/LICENSE"
  cp THIRD-PARTY-NOTICES.md "$STAGE/THIRD-PARTY-NOTICES.md"
  makensis -V2 -DARCH="$ARCH" -DVERSION="$VERSION" -DSRC="$STAGE" -DICON="$PWD/installer/nimb.ico" \
    -DOUTFILE="$OUT/Nimb-Setup-$VERSION-$ARCH.exe" installer/nimb.nsi
done
# The updater of Nimb installs only what its maker signed (Ed25519, the same key as the Mac: Updater.trustedKeys, update/update.go TrustedKeys):
# <installer>.sig goes into the release next to the installer. The private key is outside the repository; without it no update can be signed,
# and a release without .sig is refused by the updater of 0.3.1 and later (the older ones check the hash only).
SIGNING_KEY_FILE="${RELEASE_SIGNING_KEY_FILE:-$HOME/.config/nimb/release-signing.key}"
if [ -f "$SIGNING_KEY_FILE" ]; then
  for EXE in "$OUT"/Nimb-Setup-"$VERSION"-*.exe; do swift "$ROOT/scripts/sign_release.swift" sign "$EXE" >/dev/null; done
else
  echo "Note: no $SIGNING_KEY_FILE: the installers are not signed, and the updater of 0.3.1 and later refuses an update without a signature." >&2
fi
(cd "$OUT" && shasum -a 256 Nimb-Setup-"$VERSION"-*.exe | tee SHA256.txt)
if [ -n "$UNKEYED" ]; then
  {
    echo
    echo "################################################################"
    echo "#  СБОРКА БЕЗ КЛЮЧА (${UNKEYED# }): БУДЕТ «MOD», ОТЧЁТЫ НЕ УЙДУТ"
    echo "#  Нет файла $REPORT_KEY_FILE"
    echo "#  Для выпуска собирайте на Mac владельца, где этот файл есть."
    echo "################################################################"
  } >&2
else
  echo "Сборка с ключом: без «MOD» (проверено: ключ и суммы nimb-svc.exe и wintun.dll внутри Nimb.exe, для $(echo "${ARCHES[@]}"))"
fi
