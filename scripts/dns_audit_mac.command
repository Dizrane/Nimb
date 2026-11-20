#!/bin/bash
# Read-only public DNS/HTTPS checks; the user controls the VPN outside this script.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
    arm64) binary="$ROOT/build/dns-audit/dns-audit-macos-arm64" ;;
    *) binary="$ROOT/build/dns-audit/dns-audit-macos-amd64" ;;
esac
if [ ! -x "$binary" ]; then
    echo 'Диагностическая программа не собрана. Из папки windows выполните:'
    echo 'go build -o ../build/dns-audit/dns-audit-macos-arm64 ./cmd/dns-audit'
    read -r -p 'Enter — закрыть: ' _answer
    exit 1
fi
echo 'DNS Audit — диагностика на основе Nimb'
echo 'Проверяются только публичные адреса. DNS, маршруты и VPN не меняются; результат остаётся на этом Mac.'
echo 'Для проверки вашего сбоя выключите сторонний VPN и дождитесь восстановления обычного подключения.'
read -r -p 'Enter — начать три проверки, Ctrl+C — отменить: ' _answer
output="$ROOT/dns-direct-$(date +%Y%m%d-%H%M%S).json"
status=0
"$binary" -network direct -rounds 3 -interval 10s -out "$output" || status=$?
echo
if [ "$status" = 0 ]; then
    echo "Готово. Результат: $output"
    echo 'Теперь можно включить VPN обратно и вернуться в чат.'
else
    echo 'Проверка не завершилась. Прочитайте причину выше; VPN можно включить обратно.'
fi
read -r -p 'Enter — закрыть: ' _answer
exit "$status"
