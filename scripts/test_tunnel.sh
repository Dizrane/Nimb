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
# The daemon answers `get=1` with the lines of the file named by NIMB_NC_REPLY (nothing if there is none).
cat > "$WORK/bin/nc" <<'STUB'
#!/bin/sh
[ -n "${NIMB_NC_REPLY:-}" ] && cat "$NIMB_NC_REPLY"
exit 0
STUB
chmod +x "$WORK/bin/nc"
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

# The server stops answering: the watcher takes the routes out and stops the daemon, so the Mac keeps its internet, and leaves a note for
# Nimb. It does not do so while the handshake is fresh, while the Mac is offline, or while the daemon does not say anything.
now=$(date +%s)
reply() { printf 'private_key=00\nlast_handshake_time_sec=%s\nlast_handshake_time_nsec=0\nerrno=0\n' "$2" > "$WORK/run/$1.reply"; }
start_watch() { # start_watch NAME INTERFACE: a daemon that never ends by itself, its state, and a watcher
    sleep 120 & eval "$1_daemon=\$!"
    eval "d=\$$1_daemon"
    printf 'pid=%s\ninterface=%s\nroute=-host 203.0.113.7 192.0.2.1\nroute=-net 0.0.0.0/1 -interface %s\nroute=-net 128.0.0.0/1 -interface %s\nuplink=192.0.2.1 en0\n' "$d" "$2" "$2" "$2" > "$WORK/run/$1.state"
    NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/$1" NIMB_TUNNEL_PATH="$WORK/bin" NIMB_NC_REPLY="$WORK/run/$1.reply" \
        "$HELPER" watch-test "$d" 203.0.113.7 >/dev/null 2>&1 &
    eval "$1_watcher=\$!"
}
: > "$WORK/route.log"
reply stale $((now - 1000)); echo "192.0.2.1 en0" > "$WORK/run/stale.fake-uplink"; start_watch stale utun98
reply fresh "$now";          echo "192.0.2.1 en0" > "$WORK/run/fresh.fake-uplink"; start_watch fresh utun97
reply offline $((now - 1000)); : > "$WORK/run/offline.fake-uplink";                 start_watch offline utun96
: > "$WORK/run/silent.reply"; echo "192.0.2.1 en0" > "$WORK/run/silent.fake-uplink"; start_watch silent utun95
i=0; while kill -0 "$stale_watcher" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
wait "$stale_daemon" 2>/dev/null
sleep 6 # the others have had more than one round of the watcher by now
check "a silent server: the watcher ends" '! kill -0 "$stale_watcher" 2>/dev/null'
check "a silent server: the daemon is stopped" '! kill -0 "$stale_daemon" 2>/dev/null'
check "a silent server: the routes are taken out" 'grep -q "delete -net 0.0.0.0/1 -interface utun98" "$WORK/route.log" && grep -q "delete -net 128.0.0.0/1 -interface utun98" "$WORK/route.log"'
check "a silent server: the state is removed" '[ ! -f "$WORK/run/stale.state" ]'
check "a silent server: the note says why" 'grep -Eq "^[0-9]+ no-handshake$" "$WORK/run/stale.dropped"'
for name in fresh offline silent; do
    eval "d=\$${name}_daemon; w=\$${name}_watcher"
    check "$name: the tunnel is left alone" 'kill -0 "$d" 2>/dev/null && kill -0 "$w" 2>/dev/null && [ ! -f "$WORK/run/$name.dropped" ] && [ -f "$WORK/run/$name.state" ]'
done
check "the others kept their routes" '! grep -q "delete -net 0.0.0.0/1 -interface utun9[567]" "$WORK/route.log"'
for name in fresh offline silent; do eval "kill \$${name}_watcher \$${name}_daemon" 2>/dev/null; done
wait 2>/dev/null

# `down` with nothing running does nothing and does not fail.
: > "$WORK/route.log"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/none" NIMB_TUNNEL_PATH="$WORK/bin" "$HELPER" down
check "down without a tunnel is quiet" '[ $? -eq 0 ] && [ ! -s "$WORK/route.log" ]'

[ $fail = 0 ] && echo "tunnel helper: all checks passed" || { echo "tunnel helper: FAILED"; exit 1; }
