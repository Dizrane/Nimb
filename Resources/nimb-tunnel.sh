#!/bin/sh
# nimb-tunnel 8: brings the Nimb WARP tunnel up and down. It runs as root, from /usr/local/libexec/nimb, which only root
# can write to. The settings are read from warp.conf next to it, a file of plain key=value lines that Nimb wrote after
# checking every value; nothing in it is ever executed.
#
#   nimb-tunnel up      start amneziawg-go, configure it, add the routes, wait for the handshake; a small watcher then follows
#                       the network (the route to the server) and, if the daemon ends by itself, starts it again (up to three
#                       times in ten minutes; only when that fails the routes stay out and a note tells Nimb)
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
TICK=5                      # seconds between two looks of the watcher
RESTART_WAITS="0 3 15"      # seconds to wait before each try to start the daemon again
if [ -n "${NIMB_TUNNEL_TEST:-}" ]; then
    SOCKDIR="${NIMB_TUNNEL_SOCKDIR:-$SOCKDIR}"; TICK="${NIMB_TUNNEL_TICK:-$TICK}"; RESTART_WAITS="${NIMB_TUNNEL_RESTART_WAITS:-$RESTART_WAITS}"
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
    while alive "$1"; do
        sleep "$TICK"
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

cmd_up() {
    pid=$(state_get pid)
    if alive "$pid"; then say "already up"; return 0; fi
    take_down
    rm -f "$RUN.dropped"
    [ -n "${NIMB_TUNNEL_RESTART:-}" ] || rm -f "$RUN.stopped"
    [ -x "$BIN" ] || fail "нет $BIN"
    [ -f "$CONF" ] || fail "нет $CONF"

    # 1. Read the settings.
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
    host=${endpoint%:*}; port=${endpoint##*:}
    case "$host" in
        \[*\]) host=${host#\[}; host=${host%\]} ;;
    esac
    case "$host" in
        *[!0-9.]*:*) ;; # an IPv6 literal
        *[!0-9.]*) host=$(dscacheutil -q host -a name "$host" 2>/dev/null | sed -n 's/^ip_address: //p' | head -1) ;;
    esac
    [ -n "$host" ] || fail "не удалось определить адрес сервера $endpoint"
    case "$host" in *:*) endpoint="[$host]:$port" ;; *) endpoint="$host:$port" ;; esac

    # 2. Start the daemon; it makes a utun interface of its own.
    stopped_by_person && fail "остановлено"
    rm -f "$RUN.name"
    # A hangup of whatever started this script (its session, its terminal) must not take the daemon and the watcher with it: an ignored
    # signal stays ignored in the processes started from here.
    trap '' HUP
    loglevel=verbose
    [ -n "${NIMB_TUNNEL_TEST:-}" ] && loglevel=${NIMB_TUNNEL_LOG_LEVEL:-error}
    trim_log
    log_mark "up"
    WG_TUN_NAME_FILE="$RUN.name" LOG_LEVEL="$loglevel" "$BIN" -f utun >>"$LOG" 2>&1 &
    pid=$!
    i=0; while [ ! -s "$RUN.name" ] && alive "$pid" && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    iface=$(cat "$RUN.name" 2>/dev/null)
    if [ -z "$iface" ] || ! alive "$pid"; then kill "$pid" 2>/dev/null; fail "amneziawg-go не запустился (см. $LOG)"; fi
    sock="$SOCKDIR/$iface.sock"
    i=0; while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    [ -S "$sock" ] || { kill "$pid" 2>/dev/null; fail "нет управляющего сокета $sock"; }

    { printf 'pid=%s\ninterface=%s\n' "$pid" "$iface"; } > "$STATE"
    chmod 644 "$STATE"
    stopped_by_person && { take_down; fail "остановлено"; }

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
        *) take_down; fail "amneziawg-go отклонил настройки: $reply" ;;
    esac

    # 4. Address and routes.
    stopped_by_person && { take_down; fail "остановлено"; }
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
    while [ $i -lt 16 ]; do
        shake=$(printf 'get=1\n\n' | uapi "$sock" | tr -d '\r' | sed -n 's/^last_handshake_time_sec=//p' | head -1)
        [ -n "$shake" ] && [ "$shake" != 0 ] && break
        shake=0
        sleep 1; i=$((i + 1))
    done
    if [ "$shake" = 0 ]; then take_down; fail "сервер не ответил: нет рукопожатия за 16 секунд"; fi
    if [ $watching = yes ]; then
        watch_network "$pid" "$host" </dev/null >/dev/null 2>&1 &
        printf 'watcher=%s\n' "$!" >> "$STATE"
    fi
    say "up $iface $pid"
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
    down) cmd_down ;;
    status) cmd_status ;;
    retarget-test) [ -n "${NIMB_TUNNEL_TEST:-}" ] && retarget "$2" "$3" ;;
    watch-test) [ -n "${NIMB_TUNNEL_TEST:-}" ] && watch_network "$2" "$3" ;;
    *) fail "usage: nimb-tunnel up|down|status|unregister" ;;
esac
