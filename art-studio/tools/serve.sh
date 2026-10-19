#!/bin/bash
# Starts a tiny local server in art-studio and opens the viewer. Usage: tools/serve.sh [deliver/halo]
cd "$(dirname "$0")/.."
PORT=${PORT:-8765}
DIR=${1:-}
python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 0.6
if [ -n "$DIR" ]; then open "http://127.0.0.1:$PORT/tools/stage.html?dir=../$DIR"; else open "http://127.0.0.1:$PORT/tools/stage.html"; fi
echo "Просмотрщик: http://127.0.0.1:$PORT/tools/stage.html  (Ctrl+C, чтобы остановить)"
wait $SERVER
