#!/bin/sh
# Устанавливает последнюю версию Nimb из GitHub в «Программы»:
# скачивает релиз, сверяет SHA-256 (он записан в описании релиза) и подпись, заменяет старую копию и открывает приложение.
# Приложение, скачанное через curl, не получает пометку «из интернета», поэтому macOS не показывает предупреждение.
#
#   curl -fsSL https://raw.githubusercontent.com/Dizrane/Nimb/main/scripts/install.sh | sh
#
# NIMB_DEST задаёт другую папку вместо /Applications.
set -eu

REPO="Dizrane/Nimb"
DEST_DIR="${NIMB_DEST:-/Applications}"

fail() { echo "Ошибка: $1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "скрипт работает только на macOS."
[ -w "$DEST_DIR" ] || fail "нет прав на запись в $DEST_DIR. Установите вручную: перетащите Nimb.app в «Программы»."

WORK="$(mktemp -d)"
trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT

echo "Ищу последнюю версию…"
curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/release.json" \
    || fail "GitHub не отвечает."

URL="$(grep -o '"browser_download_url": *"[^"]*/Nimb-[0-9][^"]*\.zip"' "$WORK/release.json" | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$URL" ] || fail "в последнем релизе нет Nimb-*.zip."
NAME="${URL##*/}"
HASH="$(grep -o "[0-9a-f]\{64\}  *$NAME" "$WORK/release.json" | head -1 | cut -c1-64)"
[ -n "$HASH" ] || fail "в описании релиза нет SHA-256 для $NAME, установка отменена."

echo "Скачиваю $NAME…"
curl -fL --progress-bar "$URL" -o "$WORK/$NAME" || fail "не удалось скачать $NAME."
SUM="$(shasum -a 256 "$WORK/$NAME" | cut -d' ' -f1)"
[ "$SUM" = "$HASH" ] || fail "SHA-256 скачанного файла не совпадает с указанным в релизе, установка отменена."

ditto -x -k "$WORK/$NAME" "$WORK/unpacked" || fail "не удалось распаковать архив."
APP="$WORK/unpacked/Nimb.app"
[ -d "$APP" ] || fail "в архиве нет Nimb.app."
codesign --verify --deep --strict "$APP" || fail "подпись приложения не прошла проверку."

# Запущенный Nimb сначала закрываем, чтобы заменить его.
if pgrep -x Nimb >/dev/null 2>&1; then
    osascript -e 'tell application id "com.nimb.app" to quit' >/dev/null 2>&1 || true
    sleep 2
fi

DEST="$DEST_DIR/Nimb.app"
BACKUP="$DEST.old"
rm -rf "$BACKUP"
[ -e "$DEST" ] && mv "$DEST" "$BACKUP"
if ditto "$APP" "$DEST"; then
    rm -rf "$BACKUP"
else
    rm -rf "$DEST"
    [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
    fail "не удалось скопировать приложение в $DEST_DIR."
fi

echo "Готово: $NAME установлен в $DEST"
open "$DEST"
