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
check "it left a note that the daemon had ended by itself" 'grep -Eq "^[0-9]+ daemon-exited$" "$WORK/run/t.dropped"'
check "the log says that the daemon ended by itself" 'grep -Eq "^NIMB: [0-9/]+ [0-9:]+ daemon-exited$" "$WORK/run/t.log"'
kill "$watcher" 2>/dev/null

# The server does not answer: nothing is done to the tunnel. (An earlier helper switched it off after five minutes of silence, and it
# switched off tunnels that worked.) The watcher only follows the network and ends when the daemon ends.
now=$(date +%s)
printf 'private_key=00\nlast_handshake_time_sec=%s\nlast_handshake_time_nsec=0\nerrno=0\n' $((now - 1000)) > "$WORK/run/q.reply"
echo "192.0.2.1 en0" > "$WORK/run/q.fake-uplink"
# A log that has grown too big is cut to its last lines while the watcher goes on.
i=0; while [ $i -lt 5000 ]; do echo "VERBOSE: (utun98) 2026/10/22 03:49:59 line $i of a log that has grown, with some more words to fill it up"; i=$((i + 1)); done > "$WORK/run/q.log"
sleep 120 & quiet_daemon=$!
printf 'pid=%s\ninterface=utun98\nroute=-host 203.0.113.7 192.0.2.1\nroute=-net 0.0.0.0/1 -interface utun98\nroute=-net 128.0.0.0/1 -interface utun98\nuplink=192.0.2.1 en0\n' "$quiet_daemon" > "$WORK/run/q.state"
: > "$WORK/route.log"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/q" NIMB_TUNNEL_PATH="$WORK/bin" NIMB_NC_REPLY="$WORK/run/q.reply" \
    "$HELPER" watch-test "$quiet_daemon" 203.0.113.7 >/dev/null 2>&1 &
quiet_watcher=$!
sleep 12 # more than two rounds of the watcher, with a handshake that is a thousand seconds old
check "a silent server: the daemon is left alone" 'kill -0 "$quiet_daemon" 2>/dev/null'
check "a silent server: the watcher goes on" 'kill -0 "$quiet_watcher" 2>/dev/null'
check "a silent server: no route is taken out" '! grep -q "delete" "$WORK/route.log"'
check "a big log is cut to its last lines" '[ "$(wc -l < "$WORK/run/q.log" | tr -d " ")" -le 401 ] && tail -1 "$WORK/run/q.log" | grep -q "line 4999 "'
check "a silent server: no note is left" '[ ! -f "$WORK/run/q.dropped" ] && [ -f "$WORK/run/q.state" ]'
kill "$quiet_watcher" "$quiet_daemon" 2>/dev/null
wait 2>/dev/null

# `down` by the person: the watcher goes first, then the daemon; no note is left, because nothing happened that the person did not do.
sleep 120 & down_daemon=$!
sleep 120 & down_watcher=$!
printf 'pid=%s\ninterface=utun97\nroute=-net 0.0.0.0/1 -interface utun97\nwatcher=%s\n' "$down_daemon" "$down_watcher" > "$WORK/run/d.state"
: > "$WORK/route.log"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/d" NIMB_TUNNEL_PATH="$WORK/bin" "$HELPER" down
sleep 1
check "down stops the daemon and the watcher" '! kill -0 "$down_daemon" 2>/dev/null && ! kill -0 "$down_watcher" 2>/dev/null'
check "down removes the state and the routes and leaves no note" '[ ! -f "$WORK/run/d.state" ] && grep -q "delete -net 0.0.0.0/1 -interface utun97" "$WORK/route.log" && [ ! -f "$WORK/run/d.dropped" ]'
wait 2>/dev/null

# `down` with nothing running does nothing and does not fail.
: > "$WORK/route.log"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/none" NIMB_TUNNEL_PATH="$WORK/bin" "$HELPER" down
check "down without a tunnel is quiet" '[ $? -eq 0 ] && [ ! -s "$WORK/route.log" ]'

[ $fail = 0 ] && echo "tunnel helper: all checks passed" || { echo "tunnel helper: FAILED"; exit 1; }
