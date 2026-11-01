#!/bin/bash
# Puts the report relay on Cloudflare Workers (free) and connects it to your Telegram bot.
# Needs: Node.js, a free Cloudflare account, a bot from @BotFather. The token is typed here, in your terminal, and goes
# straight to Cloudflare as a secret: it is not saved in any file.
set -euo pipefail
trap 'echo "Остановилось на строке $LINENO (код $?)."' ERR
cd "$(dirname "$0")"

command -v node >/dev/null || { echo "Нужен Node.js: https://nodejs.org"; exit 1; }
npm install --no-audit --no-fund >/dev/null

echo "1/4. Вход в Cloudflare (откроется браузер, если вы ещё не вошли)"
# `wrangler whoami` ends well even when nobody is logged in, so its words are read.
if npx wrangler whoami 2>&1 | grep -qi "not authenticated"; then npx wrangler login; fi

echo
echo "2/4. Бот Telegram"
echo "   Если бота нет: откройте @BotFather, команда /newbot, и скопируйте токен."
read -r -s -p "   Токен бота: " TOKEN; echo
[ -n "$TOKEN" ] || { echo "Токен пустой."; exit 1; }
echo "   Откройте своего бота в Telegram и отправьте ему любое сообщение (например /start)."
read -r -p "   Когда отправили, нажмите Enter. " _

echo
echo "3/4. Публикация"
# Reports are also kept for 90 days, so that they can be taken all at once: a storage (KV) of this account, found or made, and written
# into wrangler.toml (made fresh from wrangler.template.toml, it stays out of the repository).
KV_ID=$(npx wrangler kv namespace list 2>/dev/null | python3 -c 'import json,sys
try:
    print(next((n["id"] for n in json.load(sys.stdin) if n.get("title") == "nimb-reports"), ""))
except Exception:
    print("")' || true)
if [ -z "$KV_ID" ]; then
    npx wrangler kv namespace create nimb-reports >/dev/null 2>&1 || true
    KV_ID=$(npx wrangler kv namespace list 2>/dev/null | python3 -c 'import json,sys
print(next((n["id"] for n in json.load(sys.stdin) if n.get("title") == "nimb-reports"), ""))')
fi
[ -n "$KV_ID" ] || { echo "Не удалось создать хранилище отчётов."; exit 1; }
cp wrangler.template.toml wrangler.toml
printf '\n[[kv_namespaces]]\nbinding = "REPORTS"\nid = "%s"\n' "$KV_ID" >> wrangler.toml
# A new Cloudflare account has no name for workers.dev yet: it is chosen once on a page of the dashboard.
while true; do
    if OUT=$(npx wrangler deploy 2>&1); then break; fi
    if echo "$OUT" | grep -q "workers.dev subdomain"; then
        LINK=$(echo "$OUT" | grep -o 'https://dash.cloudflare.com/[^ ]*onboarding' | head -1)
        echo "   Cloudflare просит один раз выбрать имя для адреса: откройте страницу, придумайте имя (например nimb-имя) и подтвердите."
        echo "   $LINK"
        [ -n "$LINK" ] && open "$LINK" >/dev/null 2>&1 || true
        read -r -p "   Когда сделали, нажмите Enter. " _
    else
        echo "$OUT"; exit 1
    fi
done
echo "$OUT" | tail -5
URL=$(echo "$OUT" | grep -o 'https://[A-Za-z0-9._-]*\.workers\.dev' | head -1)
[ -n "$URL" ] || { echo "Не нашёл адрес в ответе wrangler, посмотрите его выше."; exit 1; }
printf '%s' "$TOKEN" | npx wrangler secret put BOT_TOKEN >/dev/null
EXPORT_KEY=$(openssl rand -hex 16)
printf '%s' "$EXPORT_KEY" | npx wrangler secret put EXPORT_KEY >/dev/null
# The key that the official builds of the Mac program sign their reports with. Without it the Worker takes nothing signed.
REPORT_KEY_FILE="$HOME/.config/nimb/report.key"
if [ -f "$REPORT_KEY_FILE" ]; then
    tr -d '\n' < "$REPORT_KEY_FILE" | npx wrangler secret put REPORT_KEY >/dev/null
else
    echo "   Нет ключа отчётов ($REPORT_KEY_FILE): Worker не примет отчёты Mac новых версий."
    echo "   Создайте его командой: mkdir -p ~/.config/nimb && openssl rand -hex 32 > $REPORT_KEY_FILE && chmod 600 $REPORT_KEY_FILE"
fi

# Your chat is found by the Worker itself: from this Mac Telegram may not answer at all.
CHAT=""
for _ in 1 2 3 4 5; do
    sleep 3
    CHAT=$(curl -s -m 20 -H "Authorization: Bearer $EXPORT_KEY" "$URL/chat" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("chat") or "")
except Exception: print("")' || true)
    [ -n "$CHAT" ] && break
done
if [ -z "$CHAT" ]; then
    echo "   Не удалось найти ваш чат сам."
    read -r -p "   Введите свой числовой id (его покажет @userinfobot): " CHAT
fi
[ -n "$CHAT" ] || { echo "Нужен id чата."; exit 1; }
echo "   Чат: $CHAT"
printf '%s' "$CHAT" | npx wrangler secret put CHAT_ID >/dev/null

echo
echo "4/4. Проверка"
sleep 3
# The check is signed the way the program signs its reports (when the key is there), so it goes the way a real one goes.
BODY=$(python3 - "$REPORT_KEY_FILE" <<'PY'
import hashlib, hmac, json, os, sys
sys.path.insert(0, "../scripts")
from report_key import version_key
text = "Отчёт № SETUP1\n\nЧто случилось:\nПроверочный отчёт: ретранслятор работает."
data = {"v": 1, "id": "SETUP1", "app": "setup", "platform": "macos", "text": text}
if os.path.exists(sys.argv[1]):
    key = version_key(open(sys.argv[1]).read().strip(), data["app"]).encode()
    message = "|".join(["nimb1", data["id"], data["app"], data["platform"], "", hashlib.sha256(text.encode()).hexdigest()])
    data["sig"] = hmac.new(key, message.encode(), hashlib.sha256).hexdigest()
print(json.dumps(data, ensure_ascii=False))
PY
)
CODE=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/" -H 'content-type: application/json' -d "$BODY")
if [ "$CODE" = "200" ]; then
    echo "   Готово: проверочный отчёт ушёл, посмотрите в Telegram."
else
    echo "   Ответ $CODE. Подождите минуту и повторите: curl -X POST $URL/ ..."
fi
echo
echo "Адрес ретранслятора, его нужно вписать в приложение: $URL/"
echo
echo "Ключ для выгрузки отчётов (сохраните его, показан один раз): $EXPORT_KEY"
echo "Все накопленные отчёты одним файлом: ./export.sh (спросит ключ; с --clear выгруженные отчёты после этого удалятся)."
