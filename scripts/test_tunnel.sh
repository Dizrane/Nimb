#!/bin/sh
# Checks of Resources/nimb-tunnel.sh that need no root and touch no network: `route` is a stand-in that only writes down what it was asked.
#   ./scripts/test_tunnel.sh
set -u
cd "$(dirname "$0")/.."
HELPER="$PWD/Resources/nimb-tunnel.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/run"
cat > "$WORK/bin/route" <<STUB
#!/bin/sh
echo "\$@" >> "$WORK/route.log"
STUB
chmod +x "$WORK/bin/route"
fail=0
check() { if eval "$2"; then echo "ok:   $1"; else echo "FAIL: $1"; fail=1; fi; }

# The daemon dies without `down`: the watcher takes the routes out and removes the state, so the Mac keeps its internet.
sleep 2 & daemon=$!
printf 'pid=%s\ninterface=utun99\nroute=-host 203.0.113.7 192.0.2.1\nroute=-net 0.0.0.0/1 -interface utun99\nroute=-net 128.0.0.0/1 -interface utun99\nuplink=192.0.2.1 en0\n' "$daemon" > "$WORK/run/t.state"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/t" NIMB_TUNNEL_PATH="$WORK/bin" \
    "$HELPER" watch-test "$daemon" 203.0.113.7 >/dev/null 2>&1 &
watcher=$!
i=0; while kill -0 "$watcher" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
check "the watcher ends when the daemon is gone" '! kill -0 "$watcher" 2>/dev/null'
check "it deleted the default routes of the tunnel" 'grep -q "delete -net 0.0.0.0/1 -interface utun99" "$WORK/route.log" && grep -q "delete -net 128.0.0.0/1 -interface utun99" "$WORK/route.log"'
check "it deleted the route to the server" 'grep -q "delete -host 203.0.113.7" "$WORK/route.log"'
check "it removed the state file" '[ ! -f "$WORK/run/t.state" ]'
kill "$watcher" 2>/dev/null

# `down` with nothing running does nothing and does not fail.
: > "$WORK/route.log"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/none" NIMB_TUNNEL_PATH="$WORK/bin" "$HELPER" down
check "down without a tunnel is quiet" '[ $? -eq 0 ] && [ ! -s "$WORK/route.log" ]'

[ $fail = 0 ] && echo "tunnel helper: all checks passed" || { echo "tunnel helper: FAILED"; exit 1; }
