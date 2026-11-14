#!/bin/sh
# Windows rules run on every host; Windows-only files also build for x64 and ARM64.
# On Windows (Git Bash), this executes the native tests too. Privileged VM tests remain explicit opt-in.
set -eu
cd "$(dirname "$0")/../windows"
echo "== Windows tests ($(go env GOHOSTOS)/$(go env GOHOSTARCH))"
case "$(go env GOHOSTOS)" in
    windows) go test ./... ;;
    *) go test -race ./... ;;
esac
go vet ./...
for arch in amd64 arm64; do
    echo "== Windows build ($arch)"
    CGO_ENABLED=0 GOOS=windows GOARCH="$arch" go build ./...
done
