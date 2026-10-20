#!/bin/sh
# Reads (changes nothing) and says whether Nimb has left anything on this Mac. Run it after removing the app:
#   ./scripts/check_removed.sh
left=0
found() { echo "ОСТАЛОСЬ: $1"; left=1; }
for path in /Applications/Nimb.app "$HOME/Applications/Nimb.app" /Applications/RDNS.app \
    "$HOME/Library/Preferences/com.nimb.app.plist" "$HOME/Library/Caches/com.nimb.app" \
    "$HOME/Library/HTTPStorages/com.nimb.app" "$HOME/Library/Saved Application State/com.nimb.app.savedState" \
    "$HOME/Library/Application Support/com.nimb.app" "$HOME/Library/WebKit/com.nimb.app" "$HOME/Library/Logs/Nimb" \
    /usr/local/libexec/nimb /etc/sudoers.d/nimb /etc/sudoers.d/nimb-tunnel \
    /var/run/nimb-tunnel.state /var/run/nimb-tunnel.log /var/run/nimb-tunnel.name; do
    [ -e "$path" ] && found "$path"
done
pgrep -x Nimb >/dev/null && found "процесс Nimb"
pgrep -x amneziawg-go >/dev/null && found "процесс туннеля amneziawg-go"
nc -z 127.0.0.1 1443 2>/dev/null && found "что-то слушает порт 1443 (прокси Telegram)"
netstat -rn -f inet 2>/dev/null | grep -q '^0/1.*utun' && found "маршрут через туннель (utun)"
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while IFS= read -r service; do
    servers=$(networksetup -getdnsservers "$service" 2>/dev/null | tr '\n' ' ')
    case "$servers" in
        *143.20.64.192*|*45.13.237.213*|*83.220.169.155*|*212.109.195.93*|*159.194.200.33*|*193.233.112.67*|*192.255.159.24*)
            echo "ОСТАЛСЯ DNS Nimb на «$service»: $servers" ;;
    esac
done | grep -q . && { echo "(выше: DNS Nimb ещё стоит на подключении)"; left=1; }
# A switched-off entry stays in the list of macOS as a record and does nothing; an active one starts Nimb at login.
sfltool dumpbtm 2>/dev/null | awk '/^ *#[0-9]+:/ {block=""} {block = block "\n" $0} /Disposition:/ && block ~ /com\.nimb\.app/ && $0 ~ /enabled/ {found=1} END {exit !found}' \
    && found "включённая запись Nimb в «Объектах входа» (System Settings → General → Login Items)"
[ $left = 0 ] && echo "Чисто: следов Nimb нет." || echo "Есть остатки, см. выше."
echo "Telegram Desktop хранит свой прокси сам: Настройки → Данные и память → Тип соединения → Прокси: удалите 127.0.0.1:1443, если он остался."
