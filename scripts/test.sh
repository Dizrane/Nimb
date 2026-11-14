#!/bin/sh
# Runs Mac, Windows, relay, helper and installer checks with one command.
#   ./scripts/test.sh
# The Swift tests are built outside the project folder: in a folder synced by iCloud, macOS puts marks on the files and the signature fails.
cd "$(dirname "$0")/.." || exit 1
status=0
echo "== Swift"
log=$(mktemp)
# Testing macros may live in CLT or in the selected Xcode toolchain on CI.
plugins="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing"
[ -d "$plugins" ] || plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
run_swift_tests() {
    # The tests share AppKit and process state; avoid running those tests concurrently on small CI runners.
    swift test --no-parallel --scratch-path "${TMPDIR:-/tmp}/nimb-tests-build" \
        -Xswiftc -plugin-path -Xswiftc "$plugins"
}
if [ "${CI:-}" = true ]; then
    # Stream compiler/test progress on runners instead of hiding it until the entire Swift run exits.
    run_swift_tests > "$log" 2>&1 &
    swift_pid=$!
    tail -n +1 -f "$log" &
    log_pid=$!
    wait "$swift_pid" || status=1
    kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
else
    run_swift_tests > "$log" 2>&1 || status=1
fi
grep -v "ld: warning" "$log" | grep -E "✘|Test run|error:|Build complete" | cut -c1-200
rm -f "$log"
./scripts/test_windows.sh || status=1
echo "== Relay of reports"
(cd report-relay && node test.mjs) || status=1
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
