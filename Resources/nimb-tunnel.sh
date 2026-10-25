#!/bin/sh
# nimb-tunnel 16: brings the Nimb WARP tunnel up and down. It runs as root, from /usr/local/libexec/nimb, which only root
# can write to. The settings are read from warp.conf next to it, a file of plain key=value lines that Nimb wrote after
# checking every value; nothing in it is ever executed.
#
#   nimb-tunnel up      start amneziawg-go, configure it, add the routes, wait for the handshake; a small watcher then follows
#                       the network (the route to the server) and, if the daemon ends by itself, starts it again (up to three
#                       times in ten minutes; only when that fails the routes stay out and a note tells Nimb)
#                       When the server of the settings does not answer the handshake at all (the network may close that address), the other
#                       servers are tried before the start fails (and before Nimb thinks of new keys).
#                       When YouTube does not open through the server of the settings (the exit of some servers is filtered), it tries a few
#                       other WARP servers one after another and keeps the first that opens YouTube and Discord (a search that found nothing
#                       is not repeated for ten minutes); it happens at a start only, a tunnel that works is never moved to another server
#                       A tunnel that is up but dead (the server has not answered the handshake for ten minutes, and the internet does not
#                       answer through it either: the whole traffic of the Mac goes into it) is restarted, then moved to another server;
#                       if none answers, it is taken down, so that the Mac has its internet back, and a note tells Nimb
#   nimb-tunnel down    remove the routes and stop it
#   nimb-tunnel status  print "up <interface> <pid>" or "down"
#   nimb-tunnel unregister  delete this Mac's anonymous WARP account at Cloudflare (best effort)
#
# NIMB_TUNNEL_DIR and NIMB_TUNNEL_RUN exist for tests only and are ignored unless NIMB_TUNNEL_TEST is set.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ -n "${NIMB_TUNNEL_TEST:-}" ] && [ -n "${NIMB_TUNNEL_PATH:-}" ]; then PATH="$NIMB_TUNNEL_PATH:$PATH"; fi
DIR=/usr/local/libexec/nimb
RUN=/var/run/nimb-tunnel
if [ -n "${NIMB_TUNNEL_TEST:-}" ]; then DIR="${NIMB_TUNNEL_DIR:-$DIR}"; RUN="${NIMB_TUNNEL_RUN:-$RUN}"; fi
CONF="$DIR/warp.conf"
BIN="$DIR/amneziawg-go"
STATE="$RUN.state"
LOG="$RUN.log"
SOCKDIR=/var/run/amneziawg
case $0 in /*) SELF=$0 ;; *) SELF=$PWD/$0 ;; esac
TICK=1                      # seconds between two looks of the watcher at the daemon (the route is looked at every fifth one)
RESTART_WAITS="0 3 15"      # seconds to wait before each try to start the daemon again
if [ -n "${NIMB_TUNNEL_TEST:-}" ]; then
    SOCKDIR="${NIMB_TUNNEL_SOCKDIR:-$SOCKDIR}"; TICK="${NIMB_TUNNEL_TICK:-$TICK}"; RESTART_WAITS="${NIMB_TUNNEL_RESTART_WAITS:-$RESTART_WAITS}"
fi

# Other WARP servers to try when YouTube does not open at the one in the settings: they are reached from different cities.
SERVERS="162.159.192.1 188.114.97.1 188.114.99.1"
SEARCH_PAUSE=600            # seconds to wait after a search that found nothing
HANDSHAKE_WAIT=16           # seconds to wait for the handshake with a server
DEAD_EVERY=30               # ticks of the watcher between two looks at the age of the last handshake
DEAD_AFTER=600              # a handshake older than this (seconds) is the beginning of a dead tunnel (a healthy one renews it every two minutes)
DEAD_LOOKS=2                # looks in a row (internet dead through the tunnel too) before the tunnel is revived
PROBE_WEB=https://www.cloudflare.com/cdn-cgi/trace
PROBE_VIDEO=https://www.youtube.com/generate_204
PROBE_CHAT=https://discord.com/
if [ -n "${NIMB_TUNNEL_TEST:-}" ]; then SERVERS="${NIMB_TUNNEL_SERVERS:-$SERVERS}"; HANDSHAKE_WAIT="${NIMB_TUNNEL_HANDSHAKE_WAIT:-$HANDSHAKE_WAIT}"
    DEAD_EVERY="${NIMB_TUNNEL_DEAD_EVERY:-0}"; DEAD_AFTER="${NIMB_TUNNEL_DEAD_AFTER:-$DEAD_AFTER}"
fi

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# The log of the daemon is verbose, so that the reason is there when it ends by itself. It is cut to its last lines when it grows (the
# daemon keeps appending to the same file), and Nimb's own marks are written in the same form: "NIMB: <time> <what>".
log_mark() { printf 'NIMB: %s %s\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$1" >> "$LOG"; }
trim_log() {
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 262144 ] || return 0
    tail -n 400 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG"
    rm -f "$LOG.tmp"
}

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }

b64hex() { printf '%s' "$1" | base64 -D 2>/dev/null | xxd -p -c 256 | tr -d '\n'; }

uapi() { # uapi SOCKET  (payload on stdin)
    nc -U -w 3 "$1" 2>/dev/null
}

# The route that keeps the encrypted packets out of the tunnel itself points at the router of the network the Mac is on.
# When the Mac moves to another network, that route is stale and the tunnel cuts itself off, so a small watcher updates it.
uplink_now() { # prints "<gateway> <interface>" of the real default route, nothing while offline
    if [ -n "${NIMB_TUNNEL_TEST:-}" ] && [ -f "$RUN.fake-uplink" ]; then cat "$RUN.fake-uplink"; return; fi
    netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $4 !~ /^utun/ {print $2, $4; exit}'
}

retarget() { # retarget <endpoint host> "<gateway> <interface>"
    host=$1; gw=${2% *}; netif=${2##* }
    old=$(sed -n "s/^route=-host $host //p" "$STATE" | head -1)
    [ -n "$old" ] && route -n delete -host "$host" >/dev/null 2>&1
    case "$gw" in
        link#*|'') new="-interface $netif" ;;
        *) new="$gw" ;;
    esac
    if route -n add -host "$host" $new >/dev/null 2>&1; then
        sed -i '' -e "/^route=-host $host /d" -e "/^uplink=/d" "$STATE"
        printf 'route=-host %s %s\nuplink=%s\n' "$host" "$new" "$2" >> "$STATE"
    fi
}

# The routes of the tunnel, taken out. With a full tunnel they send every packet of the Mac into the interface of the daemon: if the
# daemon is gone and they stay, the Mac has no internet at all.
drop_routes() {
    [ -f "$STATE" ] || return 0
    sed -n 's/^route=//p' "$STATE" | while IFS= read -r route; do
        # shellcheck disable=SC2086
        route -n delete $route >/dev/null 2>&1
    done
}

watch_network() { # watch_network <daemon pid> <endpoint host>
    looks=0
    while alive "$1"; do
        sleep "$TICK"
        looks=$((looks + 1))
        if [ "$DEAD_EVERY" -gt 0 ] && [ $((looks % DEAD_EVERY)) -eq 0 ]; then dead_check; fi
        [ $((looks % 5)) -eq 0 ] || continue
        trim_log
        now=$(uplink_now)
        [ -n "$now" ] && [ "$now" != "$(state_get uplink)" ] && retarget "$2" "$now"
    done
    # The daemon stopped without `down` (killed, crashed). Without a state file `down` has already done all this.
    [ -f "$STATE" ] || return 0
    log_mark "daemon-exited"
    iface=$(state_get interface)
    watcher=$(state_get watcher)
    drop_routes
    [ -n "$iface" ] && rm -f "$SOCKDIR/$iface.sock"
    rm -f "$STATE" "$RUN.name"
    restart_daemon "$watcher" && return 0
    # It could not be started again: the Mac is left with its internet, and the note tells Nimb that it was not the person.
    printf '%s daemon-exited\n' "$(date +%s)" > "$RUN.dropped"
    chmod 644 "$RUN.dropped"
}

# The daemon is started again by the same `up`. The routes are out for those seconds (the Mac has its internet), and `$RUN.restarting`
# tells Nimb that the tunnel is only being restarted, so that its switch does not blink. A tunnel that keeps dying is left alone after three
# restarts in ten minutes. Returns 0 when it is up again or when somebody else has taken over (`down`, a new `up`).
restart_daemon() { # restart_daemon <pid of the watcher>
    since=$(( $(date +%s) - 600 ))
    recent=$([ -f "$RUN.restarts" ] && awk -v t="$since" '$1 > t' "$RUN.restarts" | wc -l | tr -d ' ')
    if [ "${recent:-0}" -ge 3 ]; then log_mark "restart skipped: three in ten minutes"; return 1; fi
    printf '%s\n' "${1:-0}" > "$RUN.restarting"
    chmod 644 "$RUN.restarting"
    for delay in $RESTART_WAITS; do
        sleep "$delay"
        if [ -f "$RUN.stopped" ] || [ -f "$STATE" ]; then rm -f "$RUN.restarting"; return 0; fi
        log_mark "restarting"
        if NIMB_TUNNEL_RESTART=1 "$SELF" up >/dev/null 2>>"$LOG"; then
            printf '%s\n' "$(date +%s)" >> "$RUN.restarts"
            chmod 644 "$RUN.restarts"
            tail -n 50 "$RUN.restarts" > "$RUN.restarts.tmp" && cat "$RUN.restarts.tmp" > "$RUN.restarts"; rm -f "$RUN.restarts.tmp"
            log_mark "restarted"
            rm -f "$RUN.restarting"
            return 0
        fi
    done
    log_mark "restart failed"
    rm -f "$RUN.restarting"
    return 1
}

cmd_status() {
    pid=$(state_get pid)
    if alive "$pid"; then say "up $(state_get interface) $pid"; else say "down"; fi
}

# `down` by the person: nothing is started again after it, even if the daemon was in the middle of a restart.
cmd_down() {
    : > "$RUN.stopped"
    restarting=$(cat "$RUN.restarting" 2>/dev/null)
    [ -n "$restarting" ] && [ "$restarting" != 0 ] && kill "$restarting" 2>/dev/null
    rm -f "$RUN.restarting"
    take_down
}

take_down() {
    [ -f "$STATE" ] || return 0
    pid=$(state_get pid)
    # The watcher first: it must not take the end of the daemon for a crash.
    watcher=$(state_get watcher)
    [ -n "$watcher" ] && kill "$watcher" 2>/dev/null
    drop_routes
    if alive "$pid"; then
        kill "$pid" 2>/dev/null
        i=0; while alive "$pid" && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
        alive "$pid" && kill -9 "$pid" 2>/dev/null
    fi
    iface=$(state_get interface)
    [ -n "$iface" ] && rm -f "$SOCKDIR/$iface.sock"
    rm -f "$STATE" "$RUN.name"
}

# A restart that the watcher started must not outlive a `down` of the person that came in the meantime.
stopped_by_person() { [ -n "${NIMB_TUNNEL_RESTART:-}" ] && [ -f "$RUN.stopped" ]; }

# The server that was found to open YouTube (written by the search below); nothing if it is not one of the known servers.
saved_server() {
    saved=$(head -1 "$DIR/server" 2>/dev/null | tr -d '[:space:]')
    for known in $SERVERS; do
        if [ "$saved" = "$known" ]; then printf '%s\n' "$saved"; return 0; fi
    done
    return 0
}

# The site answers through the tunnel (any answer of the server: the name and the handshake of TLS went through).
probe_ok() {
    code=$(curl -sI -o /dev/null -m 5 --connect-timeout 3 -w '%{http_code}' "$1" 2>/dev/null)
    case "$code" in ''|000) return 1 ;; esac
    return 0
}

good_now() { probe_ok "$PROBE_VIDEO" && probe_ok "$PROBE_CHAT"; }

# Tries the servers one after another (the one in the settings among them, unless it is the one that is up) and keeps the first at which
# YouTube and Discord both open: it is written down for the next starts. Returns 1 when none does; the tunnel is then down.
try_servers() { # try_servers <the server that is up now>
    saved=$(saved_server)
    for cand in $SERVERS conf; do
        if [ "$cand" = conf ]; then
            [ -z "$saved" ] && continue
            tryhost=""
        else
            [ "$cand" = "$1" ] && continue
            tryhost=$cand
        fi
        bring_up "$tryhost" || continue
        if good_now; then
            if [ -n "$tryhost" ]; then printf '%s\n' "$tryhost" > "$DIR/server"; else rm -f "$DIR/server"; fi
            log_mark "server ${tryhost:-of the settings} opens YouTube and Discord"
            return 0
        fi
    done
    return 1
}

# YouTube or Discord does not open at the server that is up, though the internet works: other servers are tried. A search that found
# nothing is not repeated for ten minutes (YouTube may be down everywhere, and every start would wait for it). The exit of a server can be in a city whose network filters YouTube; another server of Cloudflare leaves from another city. It all
# happens before the watcher is started, so there is never more than one of them.
search_server() {
    probe_ok "$PROBE_WEB" || return 0
    good_now && return 0
    last=$(cat "$DIR/search.at" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now=$(date +%s)
    [ $((now - last)) -lt "$SEARCH_PAUSE" ] && return 0
    current=$(state_get server)
    log_mark "server $current does not open YouTube or Discord: trying others"
    try_servers "$current" && { rm -f "$DIR/search.at"; return 0; }
    saved=$(saved_server)
    log_mark "no server opens YouTube and Discord: back to ${saved:-the settings}"
    printf '%s\n' "$(date +%s)" > "$DIR/search.at"
    if [ -n "$saved" ] && bring_up "$saved"; then return 0; fi
    bring_up ""
}

# A tunnel that is up but dead: the server has not answered the handshake for ten minutes (a healthy tunnel renews it every two minutes),
# and the internet does not answer through the tunnel either. All the traffic of the Mac goes into it, so the person has no internet at
# all until they switch the tunnel off and on. The watcher looks at the age of the last handshake every half minute (no network, only the
# daemon is asked); only when it is old, the net itself is asked, twice in a row. Not for three minutes after the Mac wakes up (the first
# handshake is still to come), and not without a network (no route to the router: the tunnel will come back with it).
dead_check() {
    now=$(date +%s)
    if [ -n "${dead_seen:-}" ] && [ $((now - dead_seen)) -gt 90 ]; then dead_grace=$((now + 180)); fi
    dead_seen=$now
    [ "$now" -lt "${dead_grace:-0}" ] && return 0
    iface=$(state_get interface)
    [ -n "$iface" ] || return 0
    shake=$(printf 'get=1\n\n' | uapi "$SOCKDIR/$iface.sock" | tr -d '\r' | sed -n 's/^last_handshake_time_sec=//p' | head -1)
    case "$shake" in ''|0|*[!0-9]*) dead_looks=0; return 0 ;; esac
    if [ $((now - shake)) -le "$DEAD_AFTER" ]; then dead_looks=0; return 0; fi
    [ -n "$(uplink_now)" ] || { dead_looks=0; return 0; }
    if probe_ok "$PROBE_WEB"; then dead_looks=0; return 0; fi
    dead_looks=$((${dead_looks:-0} + 1))
    [ "$dead_looks" -ge "$DEAD_LOOKS" ] || return 0
    dead_looks=0
    log_mark "the tunnel is dead (no handshake for $((now - shake)) s, no internet through it): reviving"
    # The child ends this watcher with its first `bring_up` (this watcher is the one of the state) and goes on without it.
    "$SELF" revive >>"$LOG" 2>&1
}

# Runs by the watcher of a dead tunnel (as root, no password): the server that is up is started again (the daemon may hold a socket of a
# network that is gone), then the others one after another; the first through which the internet answers is kept. If none is, the tunnel is
# taken down, the Mac has its internet back, and a note tells Nimb that it was not the person.
cmd_revive() {
    pid=$(state_get pid)
    alive "$pid" || return 0
    current=$(state_get server)
    read_settings
    set -m
    trap '' HUP
    NIMB_TUNNEL_RESTART=1; export NIMB_TUNNEL_RESTART
    printf '%s\n' "$PPID" > "$RUN.restarting"
    chmod 644 "$RUN.restarting"
    tried=" "
    for cand in "$current" $SERVERS conf; do
        tryhost=$cand
        if [ "$cand" = conf ]; then tryhost=""; cand=$conf_host; fi
        case "$tried" in *" $cand "*) continue ;; esac
        tried="$tried$cand "
        bring_up "$tryhost" || continue
        if probe_ok "$PROBE_WEB"; then
            case " $SERVERS " in *" $tryhost "*) [ -n "$tryhost" ] && printf '%s\n' "$tryhost" > "$DIR/server" ;; *) rm -f "$DIR/server" ;; esac
            log_mark "the tunnel is alive again at $(state_get server)"
            start_watcher
            rm -f "$RUN.restarting"
            return 0
        fi
        # Handshake, but no internet through it: the next one.
        log_mark "server ${tryhost:-of the settings} answers, but the internet does not"
    done
    take_down
    rm -f "$RUN.restarting"
    [ -f "$RUN.stopped" ] || { printf '%s no-handshake\n' "$(date +%s)" > "$RUN.dropped"; chmod 644 "$RUN.dropped"; }
    log_mark "no server answers: the tunnel is taken down, the internet is back"
    return 1
}

# The watcher follows the network and the daemon (see `watch_network`). One only, started when the server is final.
start_watcher() {
    [ "$watching" = yes ] || return 0
    watch_network "$pid" "$host" </dev/null >/dev/null 2>&1 &
    printf 'watcher=%s\n' "$!" >> "$STATE"
}

cmd_up() {
    pid=$(state_get pid)
    if alive "$pid"; then say "already up"; return 0; fi
    take_down
    rm -f "$RUN.dropped"
    [ -n "${NIMB_TUNNEL_RESTART:-}" ] || rm -f "$RUN.stopped"
    [ -x "$BIN" ] || fail "нет $BIN"
    [ -f "$CONF" ] || fail "нет $CONF"
    read_settings
    stopped_by_person && fail "остановлено"
    # The daemon and the watcher must not share the process group of whatever started this script. The administrator prompt of macOS runs
    # it under `authtrampoline`, which the system ends by itself after about twelve minutes ("idle-exit" under memory pressure), and then
    # launchd clears away the rest of its process group, the daemon among it (that is what ended the tunnel by itself). With job control
    # on, each job started below gets a group of its own and outlives it.
    set -m
    # A hangup of whatever started this script (its session, its terminal) must not take the daemon and the watcher with it: an ignored
    # signal stays ignored in the processes started from here.
    trap '' HUP
    # The server that opened YouTube last time first; if it does not answer any more, the one in the settings.
    started=no
    saved=$(saved_server)
    if [ -n "$saved" ]; then
        if bring_up "$saved"; then started=yes; else log_mark "server $saved did not answer: the one of the settings is tried"; fi
    fi
    if [ $started = no ]; then
        if bring_up ""; then
            started=yes
        elif [ -z "${NIMB_TUNNEL_RESTART:-}" ]; then
            # No handshake at all: the network may close this address (or the keys are bad, and then no server answers). The other servers
            # are tried before the start fails; a start that fails counts towards new keys, and keys that are fine must not be thrown away.
            first_error=$UPERR
            case "$UPERR" in
                *рукопожатия*)
                    for cand in $SERVERS; do
                        [ "$cand" = "$saved" ] && continue
                        if bring_up "$cand"; then started=yes; printf '%s\n' "$cand" > "$DIR/server"; log_mark "server $cand answers, the one of the settings does not"; break; fi
                    done ;;
            esac
            [ $started = yes ] || fail "$first_error"
        else
            fail "$UPERR"
        fi
    fi
    # A start by the watcher (the daemon ended by itself) is quick and does not search.
    if [ -z "${NIMB_TUNNEL_RESTART:-}" ]; then search_server || fail "$UPERR"; fi
    start_watcher
    say "up $iface $pid"
}

# 1. Reads the settings into variables, before anything is started: a mistake here changes nothing.
read_settings() {
    private_key=""; mtu=1280; addr4=""; addr6=""
    device=""; peer_keys=""; allowed=""; endpoint=""; public_key=""
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}; value=${line#*=}
        case "$key" in
            private_key) private_key=$(b64hex "$value") ;;
            address)
                case "$value" in
                    *:*) [ -z "$addr6" ] && addr6=${value%%/*} ;;
                    *) [ -z "$addr4" ] && addr4=${value%%/*} ;;
                esac ;;
            mtu) mtu=$value ;;
            public_key) public_key=$(b64hex "$value") ;;
            preshared_key) peer_keys="$peer_keys
preshared_key=$(b64hex "$value")" ;;
            endpoint) endpoint=$value ;;
            persistent_keepalive_interval|protocol_version) peer_keys="$peer_keys
$key=$value" ;;
            allowed_ip) allowed="$allowed $value" ;;
            jc|jmin|jmax|s1|s2|s3|s4|h1|h2|h3|h4|i1|i2|i3|i4|i5|header_protection_key|content_padding_addition|\
rekey_after_time|rekey_timeout|reject_after_time|keepalive_timeout|max_handshake_attempts|random_trailers|disable_cookies)
                device="$device
$key=$value" ;;
        esac
    done < "$CONF"
    # Without a keepalive nothing is sent until the first packet of the user, and the wait for the handshake below fails.
    case "$peer_keys" in *persistent_keepalive_interval*) ;; *) peer_keys="$peer_keys
persistent_keepalive_interval=25" ;; esac
    [ -n "$private_key" ] && [ -n "$public_key" ] && [ -n "$endpoint" ] || fail "в warp.conf не хватает ключа, пира или адреса сервера"

    # An endpoint that is a host name is turned into an address now, before the routes change.
    conf_host=${endpoint%:*}; port=${endpoint##*:}
    case "$conf_host" in
        \[*\]) conf_host=${conf_host#\[}; conf_host=${conf_host%\]} ;;
    esac
    case "$conf_host" in
        *[!0-9.]*:*) ;; # an IPv6 literal
        *[!0-9.]*) conf_host=$(dscacheutil -q host -a name "$conf_host" 2>/dev/null | sed -n 's/^ip_address: //p' | head -1) ;;
    esac
    [ -n "$conf_host" ] || fail "не удалось определить адрес сервера $endpoint"
}

# 2-5. Starts the daemon, configures it, adds the address and the routes and waits for the handshake with the server `$1` (empty: the one in
# the settings). On a failure it takes everything down again, says why in $UPERR and returns 1; on success `pid`, `iface`, `host` and
# `watching` say what is up (the watcher is started by `cmd_up`).
bring_up() {
    host=${1:-$conf_host}
    case "$host" in *:*) endpoint="[$host]:$port" ;; *) endpoint="$host:$port" ;; esac
    take_down
    stopped_by_person && { UPERR="остановлено"; return 1; }
    rm -f "$RUN.name"
    loglevel=verbose
    [ -n "${NIMB_TUNNEL_TEST:-}" ] && loglevel=${NIMB_TUNNEL_LOG_LEVEL:-error}
    trim_log
    log_mark "up"
    WG_TUN_NAME_FILE="$RUN.name" LOG_LEVEL="$loglevel" "$BIN" -f utun >>"$LOG" 2>&1 &
    pid=$!
    i=0; while [ ! -s "$RUN.name" ] && alive "$pid" && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    iface=$(cat "$RUN.name" 2>/dev/null)
    if [ -z "$iface" ] || ! alive "$pid"; then kill "$pid" 2>/dev/null; UPERR="amneziawg-go не запустился (см. $LOG)"; return 1; fi
    sock="$SOCKDIR/$iface.sock"
    i=0; while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    [ -S "$sock" ] || { kill "$pid" 2>/dev/null; UPERR="нет управляющего сокета $sock"; return 1; }

    { printf 'pid=%s\ninterface=%s\nserver=%s\n' "$pid" "$iface" "$host"; } > "$STATE"
    chmod 644 "$STATE"
    stopped_by_person && { take_down; UPERR="остановлено"; return 1; }

    # 3. Configure it.
    payload="set=1
private_key=$private_key$device
replace_peers=true
public_key=$public_key
endpoint=$endpoint$peer_keys
replace_allowed_ips=true"
    for cidr in $allowed; do payload="$payload
allowed_ip=$cidr"; done
    reply=$(printf '%s\n\n' "$payload" | uapi "$sock" | tr -d '\r')
    case "$reply" in
        *errno=0*) ;;
        *) take_down; UPERR="amneziawg-go отклонил настройки: $reply"; return 1 ;;
    esac

    # 4. Address and routes.
    stopped_by_person && { take_down; UPERR="остановлено"; return 1; }
    [ -n "$addr4" ] && ifconfig "$iface" inet "$addr4" "$addr4" netmask 255.255.255.255 mtu "$mtu" up
    [ -n "$addr6" ] && ifconfig "$iface" inet6 "$addr6" prefixlen 128 up >/dev/null 2>&1
    ifconfig "$iface" up
    add_route() { # add_route "<route arguments>"
        # shellcheck disable=SC2086
        if route -n add $1 >/dev/null 2>&1; then printf 'route=%s\n' "$1" >> "$STATE"; fi
    }
    full4=no; full6=no; watching=no
    for cidr in $allowed; do
        case "$cidr" in 0.0.0.0/0) full4=yes ;; ::/0) full6=yes ;; esac
    done
    if [ $full4 = yes ] && ! echo "$host" | grep -q ':'; then
        gateway=$(route -n get default 2>/dev/null | sed -n 's/^ *gateway: //p' | head -1)
        outif=$(route -n get default 2>/dev/null | sed -n 's/^ *interface: //p' | head -1)
        if [ -n "$gateway" ]; then add_route "-host $host $gateway"; elif [ -n "$outif" ]; then add_route "-host $host -interface $outif"; fi
        printf 'uplink=%s %s\n' "${gateway:-link#}" "$outif" >> "$STATE"
        watching=yes
    fi
    for cidr in $allowed; do
        case "$cidr" in
            0.0.0.0/0) add_route "-net 0.0.0.0/1 -interface $iface"; add_route "-net 128.0.0.0/1 -interface $iface" ;;
            ::/0) add_route "-inet6 -net ::/1 -interface $iface"; add_route "-inet6 -net 8000::/1 -interface $iface" ;;
            *:*) add_route "-inet6 -net $cidr -interface $iface" ;;
            *) add_route "-net $cidr -interface $iface" ;;
        esac
    done

    # 5. Wait for the handshake; without it a full tunnel would swallow all traffic, so take everything down again.
    i=0; shake=0
    while [ $i -lt "$HANDSHAKE_WAIT" ]; do
        shake=$(printf 'get=1\n\n' | uapi "$sock" | tr -d '\r' | sed -n 's/^last_handshake_time_sec=//p' | head -1)
        [ -n "$shake" ] && [ "$shake" != 0 ] && break
        shake=0
        sleep 1; i=$((i + 1))
    done
    if [ "$shake" = 0 ]; then take_down; UPERR="сервер не ответил: нет рукопожатия за $HANDSHAKE_WAIT секунд"; return 1; fi
    return 0
}

# Deletes the account that Nimb registered for this Mac. Never fails: the account expires by itself if Cloudflare is out of reach.
cmd_unregister() {
    id=""; token=""
    if [ -f "$CONF" ]; then
        id=$(sed -n 's/^account_id=//p' "$CONF" | head -1)
        token=$(sed -n 's/^account_token=//p' "$CONF" | head -1)
    fi
    case "$id" in ''|*[!0-9a-zA-Z-]*) return 0 ;; esac
    case "$token" in ''|*[!0-9a-zA-Z-]*) return 0 ;; esac
    for api in zero-trust-client.cloudflareclient.com api.cloudflareclient.com; do
        code=$(curl -s -o /dev/null -m 10 --connect-timeout 5 -X DELETE -H "Authorization: Bearer $token" \
            -w '%{http_code}' "https://$api/v0a2223/reg/$id" 2>/dev/null)
        case "$code" in 2??|404) return 0 ;; esac
    done
    return 0
}

case "${1:-}" in
    unregister) cmd_unregister ;;
    up) cmd_up ;;
    revive) cmd_revive ;;
    down) cmd_down ;;
    status) cmd_status ;;
    retarget-test) [ -n "${NIMB_TUNNEL_TEST:-}" ] && retarget "$2" "$3" ;;
    watch-test) [ -n "${NIMB_TUNNEL_TEST:-}" ] && watch_network "$2" "$3" ;;
    *) fail "usage: nimb-tunnel up|down|status|unregister" ;;
esac
