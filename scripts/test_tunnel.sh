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
# With NIMB_PROBE_DIR/shake.bad listing servers, those servers answer the configuration but never the handshake.
cat > "$WORK/bin/nc" <<'STUB'
#!/bin/sh
# `nc -z host port` (a plain connection to the server): it works unless NIMB_PROBE_DIR/wan.down exists.
case "$*" in *-z*) [ -f "${NIMB_PROBE_DIR:-/nonexistent}/wan.down" ] && exit 1; exit 0 ;; esac
payload=$(cat)
if [ -n "${NIMB_PROBE_DIR:-}" ] && [ -f "$NIMB_PROBE_DIR/shake.bad" ]; then
    server=$(sed -n 's/^server=//p' "$NIMB_TUNNEL_RUN.state" 2>/dev/null | head -1)
    case "$payload" in *get=1*) grep -qx "$server" "$NIMB_PROBE_DIR/shake.bad" && { printf 'errno=0\n'; exit 0; } ;; esac
fi
[ -n "${NIMB_NC_REPLY:-}" ] && cat "$NIMB_NC_REPLY"
exit 0
STUB
chmod +x "$WORK/bin/nc"
# `curl` answers for the probes of the helper (it asks YouTube, Discord and Cloudflare through the tunnel). Without NIMB_PROBE_DIR everything
# opens, so that no search starts; with it, YouTube opens at the servers listed in $NIMB_PROBE_DIR/video.good (the helper writes the server it
# is connected to in its state file), and the internet is gone when $NIMB_PROBE_DIR/web.down exists.
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do url=$a; done
[ -n "${NIMB_PROBE_DIR:-}" ] || { printf 204; exit 0; }
server=$(sed -n 's/^server=//p' "$NIMB_TUNNEL_RUN.state" 2>/dev/null | head -1)
case "$url" in
    *cloudflare.com*) if [ -f "$NIMB_PROBE_DIR/web.down" ] || grep -qx "$server" "$NIMB_PROBE_DIR/web.bad" 2>/dev/null; then printf 000; else printf 200; fi ;;
    *youtube.com*) grep -qx "$server" "$NIMB_PROBE_DIR/video.good" 2>/dev/null && printf 204 || printf 000 ;;
    *discord.com*) printf 200 ;;
    *) printf 000 ;;
esac
STUB
chmod +x "$WORK/bin/curl"
# `scutil` writes down what it was told (the tunnel makes itself known to the system as its primary connection and takes it away).
export NIMB_SCUTIL_LOG="$WORK/scutil.log"
cat > "$WORK/bin/scutil" <<'STUB'
#!/bin/sh
cat >> "$NIMB_SCUTIL_LOG"
STUB
chmod +x "$WORK/bin/scutil"
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
# The line of a restart is written after the new daemon is up: waits (at most 10 s) until there are $1 of them.
wait_restarts() { i=0; while [ $i -lt 10 ]; do [ "$(wc -l < "$WORK/run/r.restarts" 2>/dev/null | tr -d " ")" = "$1" ] && return 0; sleep 1; i=$((i + 1)); done; return 1; }
helper_r up >/dev/null 2>&1
pid1=$(state_pid)
check "the stand-in tunnel is up" '[ -n "$pid1" ] && kill -0 "$pid1" 2>/dev/null'
check "the tunnel does not make itself the primary connection of the system (that took the DNS of the Mac with it)" '! grep -q "OverridePrimary" "$WORK/scutil.log" && ! grep -q "^set " "$WORK/scutil.log"'
wpid1=$(sed -n 's/^watcher=//p' "$WORK/run/r.state" | head -1)
check "the daemon and the watcher have a process group each, of their own" '[ "$(ps -o pgid= -p "$pid1" | tr -d " ")" = "$pid1" ] && [ -n "$wpid1" ] && [ "$(ps -o pgid= -p "$wpid1" | tr -d " ")" = "$wpid1" ]'
kill "$pid1"; wait_new_pid "$pid1"; wait_restarts 1; pid2=$(state_pid)
check "the daemon that ended by itself is started again" '[ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && kill -0 "$pid2" 2>/dev/null'
check "a restart leaves no note and no mark of a restart in progress" '[ ! -f "$WORK/run/r.dropped" ] && [ ! -f "$WORK/run/r.restarting" ]'
check "a restart is written down, in the list and in the log" '[ "$(wc -l < "$WORK/run/r.restarts" | tr -d " ")" = 1 ] && grep -q "restarted" "$WORK/run/r.log"'
kill "$pid2"; wait_new_pid "$pid2"; wait_restarts 2; pid3=$(state_pid)
kill "$pid3"; wait_new_pid "$pid3"; wait_restarts 3; pid4=$(state_pid)
check "three restarts are made" '[ "$(wc -l < "$WORK/run/r.restarts" | tr -d " ")" = 3 ] && kill -0 "$pid4" 2>/dev/null'
kill "$pid4"
sleep 5
check "a tunnel that keeps dying is left alone: the note comes, the state goes" '[ -f "$WORK/run/r.dropped" ] && [ ! -f "$WORK/run/r.state" ] && grep -q "restart skipped" "$WORK/run/r.log"'
# `down` by the person is final: the watcher is gone with it, nothing comes up again.
: > "$WORK/run/r.restarts"
helper_r up >/dev/null 2>&1
pid5=$(state_pid)
: > "$WORK/scutil.log"
helper_r down
sleep 4
check "down takes away a record that an earlier helper may have left" 'grep -q "remove State:/Network/Service/NimbWARP/IPv4" "$WORK/scutil.log"'
check "down is final: no daemon, no state, nothing started again" '! kill -0 "$pid5" 2>/dev/null && [ ! -f "$WORK/run/r.state" ] && [ -f "$WORK/run/r.stopped" ] && [ ! -s "$WORK/run/r.restarts" ]'
check "up after down clears the sign of it" 'helper_r up >/dev/null 2>&1; [ ! -f "$WORK/run/r.stopped" ] && [ -n "$(state_pid)" ]'
helper_r down
sleep 1

# The system ends `authtrampoline` (the process that runs the helper after the password prompt) by itself after a while, and launchd then
# kills what is left in its process group. Here the process that starts the helper is the leader of a group, and the whole group is killed.
: > "$WORK/run/r.restarts"
NIMB_TUNNEL_TEST=1 NIMB_TUNNEL_DIR="$WORK" NIMB_TUNNEL_RUN="$WORK/run/r" NIMB_TUNNEL_PATH="$WORK/bin" NIMB_TUNNEL_SOCKDIR="$WORK/sock" \
    NIMB_NC_REPLY="$WORK/run/r.reply" NIMB_TUNNEL_TICK=1 NIMB_TUNNEL_RESTART_WAITS=0 \
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c '"$0" up >/dev/null 2>&1; sleep 300' "$HELPER" &
leader=$!
sleep 4
pid6=$(state_pid)
kill -9 -- "-$leader" 2>/dev/null
sleep 3
check "the group of the process that started the helper is killed: the daemon stays, as the same process" '[ -n "$pid6" ] && kill -0 "$pid6" 2>/dev/null && [ "$(state_pid)" = "$pid6" ] && [ ! -s "$WORK/run/r.restarts" ]'
helper_r down
sleep 1

# YouTube does not open at the server of the settings: other servers are tried, the first that opens YouTube and Discord is kept, and it is
# used at the next start. A search comes once in six hours at the most, and not when the internet is gone.
PROBE="$WORK/probe"; mkdir -p "$PROBE"
export NIMB_PROBE_DIR="$PROBE" NIMB_TUNNEL_SERVERS="198.51.100.1 198.51.100.2"
state_server() { sed -n 's/^server=//p' "$WORK/run/r.state" 2>/dev/null | head -1; }
searches() { grep -c "does not open YouTube" "$WORK/run/r.log" 2>/dev/null || true; }
rm -f "$WORK/server" "$WORK/search.at" "$PROBE/web.down"
exited_before=$(grep -c "daemon-exited" "$WORK/run/r.log" 2>/dev/null || true)
echo 198.51.100.2 > "$PROBE/video.good"
helper_r up >/dev/null 2>&1
check "YouTube opens at the second server tried: the tunnel is up at it" '[ "$(state_server)" = 198.51.100.2 ]'
check "after a search there is one watcher, and it is the one of the state" '[ "$(pgrep -f "$HELPER" | wc -l | tr -d " ")" = 1 ] && [ "$(pgrep -f "$HELPER")" = "$(sed -n "s/^watcher=//p" "$WORK/run/r.state")" ]'
check "the server that opened YouTube is kept, and the search leaves no pause behind" '[ "$(cat "$WORK/server")" = 198.51.100.2 ] && [ ! -f "$WORK/search.at" ] && grep -q "opens YouTube" "$WORK/run/r.log"'
helper_r down; sleep 1
n_before=$(searches)
helper_r up >/dev/null 2>&1
check "the next start uses the kept server and does not search again" '[ "$(state_server)" = 198.51.100.2 ] && [ "$(searches)" = "$n_before" ]'
helper_r down; sleep 1
echo 203.0.113.7 > "$PROBE/video.good"; rm -f "$WORK/search.at"
helper_r up >/dev/null 2>&1
check "the kept server stopped opening YouTube: the one of the settings is found good, and the kept one is forgotten" '[ "$(state_server)" = 203.0.113.7 ] && [ ! -f "$WORK/server" ]'
helper_r down; sleep 1
: > "$PROBE/video.good"; rm -f "$WORK/search.at"; n_before=$(searches)
helper_r up >/dev/null 2>&1
check "no server opens YouTube: back at the server of the settings, nothing is kept" '[ "$(state_server)" = 203.0.113.7 ] && [ ! -f "$WORK/server" ] && grep -q "no server opens YouTube" "$WORK/run/r.log" && [ "$(searches)" -gt "$n_before" ]'
helper_r down; sleep 1
n_before=$(searches)
helper_r up >/dev/null 2>&1
check "a search that has just been made is not made again" '[ "$(searches)" = "$n_before" ] && [ "$(state_server)" = 203.0.113.7 ]'
helper_r down; sleep 1
rm -f "$WORK/search.at"; touch "$PROBE/web.down"; n_before=$(searches)
helper_r up >/dev/null 2>&1
check "the internet is gone: it is not a matter of the server, no search" '[ "$(searches)" = "$n_before" ] && [ ! -f "$WORK/search.at" ]'
helper_r down; sleep 1
rm -f "$PROBE/web.down" "$WORK/server" "$WORK/search.at"
# The server of the settings does not answer the handshake (the network may close it): the other servers are tried before the start fails.
export NIMB_TUNNEL_HANDSHAKE_WAIT=2
rm -f "$WORK/server" "$WORK/search.at"
printf '203.0.113.7\n' > "$PROBE/shake.bad"
printf '198.51.100.1\n198.51.100.2\n' > "$PROBE/video.good"
helper_r up >/dev/null 2>&1
check "no handshake at the server of the settings: the tunnel is up at another server, and it is kept" '[ "$(state_server)" = 198.51.100.1 ] && [ "$(cat "$WORK/server")" = 198.51.100.1 ]'
helper_r down; sleep 1
# No server answers: the start fails with the usual words (they count towards new keys), nothing is left running or kept.
rm -f "$WORK/server"
printf '203.0.113.7\n198.51.100.1\n198.51.100.2\n' > "$PROBE/shake.bad"
message=$(helper_r up 2>&1 >/dev/null); code=$?
check "no server answers: the start fails with the words about the handshake" '[ "$code" != 0 ] && echo "$message" | grep -q "рукопожатия"'
check "and nothing is left: no state, no server kept" '[ ! -f "$WORK/run/r.state" ] && [ ! -f "$WORK/server" ]'
rm -f "$PROBE/shake.bad"

# A tunnel that is up but dead: the handshake is old (here the stand-in always says so) and the internet does not answer through it. Two looks of
# the watcher in a row, then the server is started again, the others after it; none answers: the tunnel is taken down for the internet.
export NIMB_TUNNEL_DEAD_EVERY=2 NIMB_TUNNEL_DEAD_AFTER=60
rm -f "$WORK/server" "$WORK/search.at" "$PROBE/web.down" "$PROBE/web.bad" "$WORK/run/r.dropped"
printf '203.0.113.7\n198.51.100.1\n198.51.100.2\n' > "$PROBE/video.good"
helper_r up >/dev/null 2>&1
sleep 7
check "an old handshake and a working internet: the tunnel is left alone" '[ "$(state_server)" = 203.0.113.7 ] && ! grep -q "the tunnel is dead" "$WORK/run/r.log"'
printf '203.0.113.7\n' > "$PROBE/web.bad"
i=0; while [ $i -lt 40 ] && [ "$(state_server)" != 198.51.100.1 ]; do sleep 1; i=$((i + 1)); done
sleep 1
check "a dead tunnel is moved to a server through which the internet answers, and it is kept" '[ "$(state_server)" = 198.51.100.1 ] && [ "$(cat "$WORK/server")" = 198.51.100.1 ] && grep -q "the tunnel is dead" "$WORK/run/r.log" && [ ! -f "$WORK/run/r.dropped" ] && [ ! -f "$WORK/run/r.restarting" ]'
check "and there is one watcher after it" '[ "$(pgrep -f "$HELPER" | wc -l | tr -d " ")" = 1 ] && [ "$(pgrep -f "$HELPER")" = "$(sed -n "s/^watcher=//p" "$WORK/run/r.state")" ]'
printf '203.0.113.7\n198.51.100.1\n' > "$PROBE/web.bad"
: > "$WORK/run/r.fake-uplink"
n_dead=$(grep -c "the tunnel is dead" "$WORK/run/r.log")
sleep 8
check "no network at all (no route to the router): the tunnel is left alone, it will come back with the network" '[ "$(grep -c "the tunnel is dead" "$WORK/run/r.log")" = "$n_dead" ] && [ "$(state_server)" = 198.51.100.1 ]'
echo "192.0.2.1 en0" > "$WORK/run/r.fake-uplink"
# The internet of the Mac is down (the server cannot be reached the usual way either): not the tunnel's trouble, it is left to come back.
touch "$PROBE/web.down" "$PROBE/wan.down"
sleep 9
check "the server cannot be reached the usual way: the internet is down, the tunnel is left alone" '[ "$(grep -c "the tunnel is dead" "$WORK/run/r.log")" = "$n_dead" ] && [ "$(state_server)" = 198.51.100.1 ] && grep -q "the internet of the Mac is down" "$WORK/run/r.log" && [ ! -f "$WORK/run/r.dropped" ]'
rm -f "$PROBE/wan.down"
i=0; while [ $i -lt 60 ] && [ ! -f "$WORK/run/r.dropped" ]; do sleep 1; i=$((i + 1)); done
sleep 1
check "no server answers: the tunnel is taken down, nothing is left running, and the note says it was not the person" '[ ! -f "$WORK/run/r.state" ] && grep -Eq "^[0-9]+ no-handshake$" "$WORK/run/r.dropped" && ! pgrep -f "$WORK/amneziawg-go" >/dev/null && ! pgrep -f "$HELPER" >/dev/null && [ ! -f "$WORK/run/r.restarting" ]'
rm -f "$PROBE/web.down" "$PROBE/web.bad" "$WORK/run/r.dropped" "$WORK/server"
unset NIMB_TUNNEL_DEAD_EVERY NIMB_TUNNEL_DEAD_AFTER
unset NIMB_TUNNEL_HANDSHAKE_WAIT
check "a search never makes the daemon look as if it ended by itself" '[ "$(grep -c "daemon-exited" "$WORK/run/r.log" 2>/dev/null || true)" = "$exited_before" ]'
unset NIMB_PROBE_DIR NIMB_TUNNEL_SERVERS

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
