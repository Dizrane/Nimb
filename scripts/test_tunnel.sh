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
[ "\$1 \$2 \$3" = "-n get default" ] && printf '   gateway: 192.0.2.1\n  interface: en0\n'
exit 0
STUB
chmod +x "$WORK/bin/route"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/ifconfig"
chmod +x "$WORK/bin/ifconfig"
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
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/t" NIMB_TUNNEL_PATH="$WORK/bin" NIMB_TUNNEL_TICK=1 NIMB_TUNNEL_RESTART_WAITS=0 \
    "$HELPER" watch-test "$daemon" 203.0.113.7 >/dev/null 2>&1 &
watcher=$!
i=0; while kill -0 "$watcher" 2>/dev/null && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
check "the watcher ends when the daemon is gone" '! kill -0 "$watcher" 2>/dev/null'
check "it deleted the default routes of the tunnel" 'grep -q "delete -net 0.0.0.0/1 -interface utun99" "$WORK/route.log" && grep -q "delete -net 128.0.0.0/1 -interface utun99" "$WORK/route.log"'
check "it deleted the route to the server" 'grep -q "delete -host 203.0.113.7" "$WORK/route.log"'
check "it removed the state file" '[ ! -f "$WORK/run/t.state" ]'
check "it left a note that the daemon had ended by itself" 'grep -Eq "^[0-9]+ daemon-exited$" "$WORK/run/t.dropped"'
check "a restart that cannot start the daemon leaves it noted" 'grep -q "restart failed" "$WORK/run/t.log" && [ ! -f "$WORK/run/t.restarting" ]'
check "the log says that the daemon ended by itself" 'grep -Eq "^NIMB: [0-9/]+ [0-9:]+ daemon-exited$" "$WORK/run/t.log"'
kill "$watcher" 2>/dev/null

# The daemon ends by itself while the tunnel is up: the watcher starts it again, nothing is noted, the switch of Nimb has no reason to blink.
# A stand-in for the daemon: it names its interface, makes the socket and sleeps.
cat > "$WORK/amneziawg-go" <<'STUB'
#!/usr/bin/python3
import os, socket, time
open(os.environ["WG_TUN_NAME_FILE"], "w").write("utun96\n")
path = os.path.join(os.environ["NIMB_TUNNEL_SOCKDIR"], "utun96.sock")
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.listen(1)
time.sleep(300)
STUB
chmod +x "$WORK/amneziawg-go"
mkdir -p "$WORK/sock"
printf 'private_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\npublic_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nendpoint=203.0.113.7:2408\naddress=172.16.0.2/32\nallowed_ip=0.0.0.0/0\n' > "$WORK/warp.conf"
printf 'errno=0\nlast_handshake_time_sec=1700000000\nlast_handshake_time_nsec=0\n' > "$WORK/run/r.reply"
echo "192.0.2.1 en0" > "$WORK/run/r.fake-uplink"
helper_r() {
    NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/r" NIMB_TUNNEL_PATH="$WORK/bin" NIMB_TUNNEL_SOCKDIR="$WORK/sock" \
        NIMB_NC_REPLY="$WORK/run/r.reply" NIMB_TUNNEL_TICK=1 NIMB_TUNNEL_RESTART_WAITS=0 "$HELPER" "$@"
}
state_pid() { sed -n 's/^pid=//p' "$WORK/run/r.state" 2>/dev/null | head -1; }
# Waits (at most 15 s) until the tunnel runs with a pid other than $1.
wait_new_pid() { i=0; while [ $i -lt 15 ]; do p=$(state_pid); [ -n "$p" ] && [ "$p" != "$1" ] && kill -0 "$p" 2>/dev/null && return 0; sleep 1; i=$((i + 1)); done; return 1; }
helper_r up >/dev/null 2>&1
pid1=$(state_pid)
check "the stand-in tunnel is up" '[ -n "$pid1" ] && kill -0 "$pid1" 2>/dev/null'
kill "$pid1"; wait_new_pid "$pid1"; pid2=$(state_pid)
check "the daemon that ended by itself is started again" '[ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && kill -0 "$pid2" 2>/dev/null'
check "a restart leaves no note and no mark of a restart in progress" '[ ! -f "$WORK/run/r.dropped" ] && [ ! -f "$WORK/run/r.restarting" ]'
check "a restart is written down, in the list and in the log" '[ "$(wc -l < "$WORK/run/r.restarts" | tr -d " ")" = 1 ] && grep -q "restarted" "$WORK/run/r.log"'
kill "$pid2"; wait_new_pid "$pid2"; pid3=$(state_pid)
kill "$pid3"; wait_new_pid "$pid3"; pid4=$(state_pid)
check "three restarts are made" '[ "$(wc -l < "$WORK/run/r.restarts" | tr -d " ")" = 3 ] && kill -0 "$pid4" 2>/dev/null'
kill "$pid4"
sleep 5
check "a tunnel that keeps dying is left alone: the note comes, the state goes" '[ -f "$WORK/run/r.dropped" ] && [ ! -f "$WORK/run/r.state" ] && grep -q "restart skipped" "$WORK/run/r.log"'
# `down` by the person is final: the watcher is gone with it, nothing comes up again.
: > "$WORK/run/r.restarts"
helper_r up >/dev/null 2>&1
pid5=$(state_pid)
helper_r down
sleep 4
check "down is final: no daemon, no state, nothing started again" '! kill -0 "$pid5" 2>/dev/null && [ ! -f "$WORK/run/r.state" ] && [ -f "$WORK/run/r.stopped" ] && [ ! -s "$WORK/run/r.restarts" ]'
check "up after down clears the sign of it" 'helper_r up >/dev/null 2>&1; [ ! -f "$WORK/run/r.stopped" ] && [ -n "$(state_pid)" ]'
helper_r down
sleep 1

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
