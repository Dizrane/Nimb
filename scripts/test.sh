#!/bin/sh
# Runs every check of the project: the Swift tests, the tests of the relay of reports (Node.js), of the tunnel helper and of the installer script.
#   ./scripts/test.sh
# The Swift tests are built outside the project folder: in a folder synced by iCloud, macOS puts marks on the files and the signature fails.
cd "$(dirname "$0")/.." || exit 1
status=0
echo "== Swift"
log=$(mktemp)
swift test --scratch-path "${TMPDIR:-/tmp}/nimb-tests-build" \
    -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing > "$log" 2>&1 || status=1
grep -v "ld: warning" "$log" | grep -E "✘|Test run|error:|Build complete" | cut -c1-200
rm -f "$log"
echo "== Relay of reports"
(cd report-relay && { [ -d node_modules ] || npm install --no-audit --no-fund >/dev/null; } && node test.mjs) || status=1
echo "== Key of a version"
# The build script and the relay (report-relay/test.mjs) must make the same key of a version from the master key.
keyfile=$(mktemp)
printf 'test-master\n' > "$keyfile"
[ "$(python3 scripts/report_key.py derive "$keyfile" 0.9.23)" = "9297899018b3ede3fff74dc1a582516c01c52cb17aaa53aa593f5cdcd87c10b0" ] \
    && echo "version key: ok" || { echo "version key: differs from the relay's"; status=1; }
rm -f "$keyfile"
echo "== Tunnel helper"
./scripts/test_tunnel.sh || status=1
echo "== Installer script"
./scripts/test_install.sh || status=1
[ $status = 0 ] && echo "ALL GOOD" || echo "SOMETHING FAILED"
exit $status
