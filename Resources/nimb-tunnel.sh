#!/bin/sh
# nimb-tunnel 1: brings the Nimb WARP tunnel up and down. It runs as root, from /usr/local/libexec/nimb, which only root
# can write to. The settings are read from warp.conf next to it, a file of plain key=value lines that Nimb wrote after
# checking every value; nothing in it is ever executed.
#
#   nimb-tunnel up      start amneziawg-go, configure it, add the routes, wait for the handshake
#   nimb-tunnel down    remove the routes and stop it
#   nimb-tunnel status  print "up <interface> <pid>" or "down"
#
# NIMB_TUNNEL_DIR and NIMB_TUNNEL_RUN exist for tests only and are ignored unless NIMB_TUNNEL_TEST is set.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
DIR=/usr/local/libexec/nimb
RUN=/var/run/nimb-tunnel
if [ -n "${NIMB_TUNNEL_TEST:-}" ]; then DIR="${NIMB_TUNNEL_DIR:-$DIR}"; RUN="${NIMB_TUNNEL_RUN:-$RUN}"; fi
CONF="$DIR/warp.conf"
BIN="$DIR/amneziawg-go"
STATE="$RUN.state"
LOG="$RUN.log"
SOCKDIR=/var/run/amneziawg

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }

b64hex() { printf '%s' "$1" | base64 -D 2>/dev/null | xxd -p -c 256 | tr -d '\n'; }

uapi() { # uapi SOCKET  (payload on stdin)
    nc -U -w 3 "$1" 2>/dev/null
}

cmd_status() {
    pid=$(state_get pid)
    if alive "$pid"; then say "up $(state_get interface) $pid"; else say "down"; fi
}

cmd_down() {
    [ -f "$STATE" ] || return 0
    pid=$(state_get pid)
    sed -n 's/^route=//p' "$STATE" | while IFS= read -r route; do
        # shellcheck disable=SC2086
        route -n delete $route >/dev/null 2>&1
    done
    if alive "$pid"; then
        kill "$pid" 2>/dev/null
        i=0; while alive "$pid" && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
        alive "$pid" && kill -9 "$pid" 2>/dev/null
    fi
    iface=$(state_get interface)
    [ -n "$iface" ] && rm -f "$SOCKDIR/$iface.sock"
    rm -f "$STATE" "$RUN.name"
}

cmd_up() {
    pid=$(state_get pid)
    if alive "$pid"; then say "already up"; return 0; fi
    cmd_down
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
    rm -f "$RUN.name"
    WG_TUN_NAME_FILE="$RUN.name" LOG_LEVEL=error "$BIN" -f utun >>"$LOG" 2>&1 &
    pid=$!
    i=0; while [ ! -s "$RUN.name" ] && alive "$pid" && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    iface=$(cat "$RUN.name" 2>/dev/null)
    if [ -z "$iface" ] || ! alive "$pid"; then kill "$pid" 2>/dev/null; fail "amneziawg-go не запустился (см. $LOG)"; fi
    sock="$SOCKDIR/$iface.sock"
    i=0; while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    [ -S "$sock" ] || { kill "$pid" 2>/dev/null; fail "нет управляющего сокета $sock"; }

    { printf 'pid=%s\ninterface=%s\n' "$pid" "$iface"; } > "$STATE"
    chmod 644 "$STATE"

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
        *) cmd_down; fail "amneziawg-go отклонил настройки: $reply" ;;
    esac

    # 4. Address and routes.
    [ -n "$addr4" ] && ifconfig "$iface" inet "$addr4" "$addr4" netmask 255.255.255.255 mtu "$mtu" up
    [ -n "$addr6" ] && ifconfig "$iface" inet6 "$addr6" prefixlen 128 up >/dev/null 2>&1
    ifconfig "$iface" up
    add_route() { # add_route "<route arguments>"
        # shellcheck disable=SC2086
        if route -n add $1 >/dev/null 2>&1; then printf 'route=%s\n' "$1" >> "$STATE"; fi
    }
    full4=no; full6=no
    for cidr in $allowed; do
        case "$cidr" in 0.0.0.0/0) full4=yes ;; ::/0) full6=yes ;; esac
    done
    if [ $full4 = yes ] && ! echo "$host" | grep -q ':'; then
        gateway=$(route -n get default 2>/dev/null | sed -n 's/^ *gateway: //p' | head -1)
        outif=$(route -n get default 2>/dev/null | sed -n 's/^ *interface: //p' | head -1)
        if [ -n "$gateway" ]; then add_route "-host $host $gateway"; elif [ -n "$outif" ]; then add_route "-host $host -interface $outif"; fi
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
    if [ "$shake" = 0 ]; then cmd_down; fail "сервер не ответил: нет рукопожатия за 16 секунд"; fi
    say "up $iface $pid"
}

case "${1:-}" in
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    *) fail "usage: nimb-tunnel up|down|status" ;;
esac
