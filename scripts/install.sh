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

# The newest release for the Mac. The repository also holds releases of the Windows version, so "the latest release" of GitHub is not
# enough: this takes the first published one that is not a pre-release, has a tag like v0.9.9 and has the archive Nimb-<version>.zip.
# GitHub lists the newest first. The release is read with plutil, which takes JSON apart (macOS 12 and newer).
pick_release() { # pick_release FILE: prints "<archive address>" and the notes of the release (NOTES), or nothing
    i=0
    while tag=$(plutil -extract "$i.tag_name" raw -o - "$1" 2>/dev/null); do
        draft=$(plutil -extract "$i.draft" raw -o - "$1" 2>/dev/null)
        pre=$(plutil -extract "$i.prerelease" raw -o - "$1" 2>/dev/null)
        case "$tag" in
            "" | *[!0-9.vV]*) ;; # windows-v0.1.0, v1.0-beta and the like are not releases of the Mac
            [vV][0-9]* | [0-9]*)
                if [ "$draft" = false ] && [ "$pre" = false ]; then
                    j=0
                    while name=$(plutil -extract "$i.assets.$j.name" raw -o - "$1" 2>/dev/null); do
                        case "$name" in
                            Nimb-[0-9]*.zip)
                                plutil -extract "$i.assets.$j.browser_download_url" raw -o - "$1"
                                plutil -extract "$i.body" raw -o - "$1" 2>/dev/null
                                return 0 ;;
                        esac
                        j=$((j + 1))
                    done
                fi ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# Verify the author's Ed25519 signature before unpacking or replacing anything. The public keys are the same as
# Updater.trustedKeys. macOS's LibreSSL cannot verify Ed25519, so use the system CryptoKit through Swift; with no
# developer tools available, fail closed instead of treating a hash from the same release as proof of authorship.
verify_signature() { # verify_signature ARCHIVE SIGNATURE [VERIFIER_OUTPUT]
    verifier="$WORK/verify-signature.swift"
    cat > "$verifier" <<'SWIFT'
    import CryptoKit
    import Foundation

    let trustedKeys = ["A8Hv9MEsL+jtyYnniwH1PART5CiHUZqgJofpqRz/ttE="]
    let args = CommandLine.arguments
    guard args.count == 3,
          let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let text = try? String(contentsOfFile: args[2], encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          signature.count == 64 else { exit(1) }
    let valid = trustedKeys.contains { encoded in
        guard let raw = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }
    exit(valid ? 0 : 1)
SWIFT
    /usr/bin/swift -module-cache-path "$WORK/swift-cache" "$verifier" "$1" "$2" > "${3:-/dev/null}" 2>&1
}

echo "Ищу последнюю версию…"
command -v plutil >/dev/null 2>&1 || fail "не нашёл plutil: нужна macOS 12 или новее."
# Check without invoking xcrun/swift first: on a Mac without Command Line Tools they can open an installation dialog.
/usr/bin/xcode-select -p >/dev/null 2>&1 && /usr/bin/xcrun --find swift >/dev/null 2>&1 \
    || fail "для проверки подписи нужен Swift из Command Line Tools или Xcode. Установите инструменты Apple либо скачайте DMG со страницы релиза вручную. Установка не начата."
curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases?per_page=20" -o "$WORK/release.json" \
    || fail "GitHub не отвечает."

PICKED="$(pick_release "$WORK/release.json")" || fail "в списке релизов нет релиза Nimb для Mac с файлом Nimb-*.zip."
URL="$(printf '%s\n' "$PICKED" | head -1)"
NOTES="$(printf '%s\n' "$PICKED" | tail -n +2)"
NAME="${URL##*/}"
HASH="$(printf '%s\n' "$NOTES" | grep -o "[0-9a-f]\{64\}  *$NAME" | head -1 | cut -c1-64)"
[ -n "$HASH" ] || fail "в описании релиза нет SHA-256 для $NAME, установка отменена."

echo "Скачиваю ${NAME}…"
curl -fL --progress-bar "$URL" -o "$WORK/$NAME" || fail "не удалось скачать $NAME."
SUM="$(shasum -a 256 "$WORK/$NAME" | cut -d' ' -f1)"
[ "$SUM" = "$HASH" ] || fail "SHA-256 скачанного файла не совпадает с указанным в релизе, установка отменена."

curl -fsSL "$URL.sig" -o "$WORK/$NAME.sig" || fail "не удалось скачать подпись автора $NAME.sig, установка отменена."
echo "Проверяю подпись автора…"
verify_signature "$WORK/$NAME" "$WORK/$NAME.sig" "$WORK/verify.log" \
    || fail "не удалось проверить подпись автора. Файл мог быть изменён или средства проверки недоступны. Установка отменена."

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
