#!/bin/bash
# Builds Resources/amneziawg-go, the userspace AmneziaWG daemon (https://github.com/amnezia-vpn/amneziawg-go, MIT) as one
# universal binary (Apple Silicon and Intel). There is no ready-made build for macOS. Needs Go (https://go.dev/dl/):
#   GO=/path/to/go ./scripts/build_awg.sh        (GO defaults to the `go` in PATH)
# The commit is pinned so that the same sources give the same program.
set -euo pipefail
cd "$(dirname "$0")/.."

COMMIT="b5928efb6ca19f0153958460c3d141f04abc5c2e"
GO="${GO:-$(command -v go || true)}"
[ -n "$GO" ] && [ -x "$GO" ] || { echo "Нужен Go (https://go.dev/dl/): задайте GO=/путь/к/go или добавьте go в PATH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT
git clone -q https://github.com/amnezia-vpn/amneziawg-go.git "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"

for arch in arm64 amd64; do
    (cd "$WORK/src" && GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 "$GO" build -trimpath -ldflags="-s -w" -o "$WORK/awg-$arch" .)
done
lipo -create -output Resources/amneziawg-go "$WORK/awg-arm64" "$WORK/awg-amd64"
echo "Built Resources/amneziawg-go ($(lipo -archs Resources/amneziawg-go))"
