#!/bin/bash
# Takes all the kept reports from the relay as one text file in the current folder: nimb-reports-<date>.txt
#   ./export.sh            the key is asked here (or taken from NIMB_EXPORT_KEY); it is sent in a header, never in the address
#   ./export.sh --clear    and deletes the reports that were taken
set -euo pipefail
cd "$(dirname "$0")"
URL=$(grep -o 'https://[A-Za-z0-9._-]*\.workers\.dev/' ../Sources/Nimb/Report/ReportSender.swift | head -1)
[ -n "$URL" ] || { echo "Не нашёл адрес ретранслятора в ReportSender.swift."; exit 1; }
KEY="${NIMB_EXPORT_KEY:-}"
if [ -z "$KEY" ]; then read -r -s -p "Ключ выгрузки: " KEY; echo; fi
[ -n "$KEY" ] || { echo "Ключ пустой."; exit 1; }
QUERY=""; [ "${1:-}" = "--clear" ] && QUERY="?clear=1"
OUT="$PWD/nimb-reports-$(date +%Y-%m-%d).txt"
CODE=$(curl -s -m 60 -o "$OUT" -w '%{http_code}' -H "Authorization: Bearer $KEY" "${URL}export$QUERY")
if [ "$CODE" = "200" ]; then echo "Готово: $OUT"; else rm -f "$OUT"; echo "Ответ $CODE: ключ неверный или ретранслятор не отвечает."; exit 1; fi
