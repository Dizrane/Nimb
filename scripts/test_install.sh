#!/bin/sh
# Checks of release selection and author-signature verification in scripts/install.sh. No network or release private keys:
# signatures are made with a fresh, temporary test key, substituted only in a temporary copy of the installer.
#   ./scripts/test_install.sh
set -u
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sed -n '/^pick_release()/,/^}/p' scripts/install.sh > "$WORK/pick.sh"
fail=0
check() { if eval "$2"; then echo "ok:   $1"; else echo "FAIL: $1"; fail=1; fi; }

# release TAG DRAFT PRERELEASE ASSET...  -> one object of the list
release() {
    tag=$1; draft=$2; pre=$3; shift 3
    assets=""
    for name in "$@"; do assets="$assets${assets:+,}{\"name\":\"$name\",\"browser_download_url\":\"https://example.test/$tag/$name\"}"; done
    printf '{"tag_name":"%s","draft":%s,"prerelease":%s,"body":"hash for %s","assets":[%s]}' "$tag" "$draft" "$pre" "$tag" "$assets"
}
list() { # list OBJECT... -> a JSON array in $WORK/list.json
    out="["; sep=""
    for object in "$@"; do out="$out$sep$object"; sep=","; done
    printf '%s]' "$out" > "$WORK/list.json"
}
picked() { sh -c ". '$WORK/pick.sh'; pick_release '$WORK/list.json'" 2>/dev/null; }

list "$(release windows-v0.1.0 false false Nimb-Setup-0.1.0-amd64.exe Nimb-1.0.zip)" "$(release v0.9.9 false false Nimb-0.9.9.dmg Nimb-0.9.9.zip)"
check "a release of the Windows version made the latest is skipped" '[ "$(picked | head -1)" = "https://example.test/v0.9.9/Nimb-0.9.9.zip" ]'
check "the notes of the release come with the address" '[ "$(picked | tail -n +2)" = "hash for v0.9.9" ]'

list "$(release v1.0.0 false true Nimb-1.0.0.zip)" "$(release v0.9.9 false false Nimb-0.9.9.zip)"
check "a pre-release is skipped" '[ "$(picked | head -1)" = "https://example.test/v0.9.9/Nimb-0.9.9.zip" ]'

list "$(release v1.0.0 true false Nimb-1.0.0.zip)" "$(release v0.9.9 false false Nimb-0.9.9.zip)"
check "a draft is skipped" '[ "$(picked | head -1)" = "https://example.test/v0.9.9/Nimb-0.9.9.zip" ]'

list "$(release v1.0.0-beta false false Nimb-1.0.0.zip)" "$(release v0.9.9 false false Nimb-0.9.9.zip)"
check "a tag with a word in it is skipped" '[ "$(picked | head -1)" = "https://example.test/v0.9.9/Nimb-0.9.9.zip" ]'

list "$(release v0.9.10 false false Nimb-0.9.10.dmg)" "$(release v0.9.9 false false Nimb-0.9.9.zip)"
check "a release without the archive is skipped" '[ "$(picked | head -1)" = "https://example.test/v0.9.9/Nimb-0.9.9.zip" ]'

list "$(release windows-v0.1.0 false false Nimb-Setup-0.1.0-amd64.exe)" "$(release windows-v0.0.9 false true Nimb-Setup-0.0.9-amd64.exe)"
check "no release for the Mac: nothing is picked and the status says so" '[ -z "$(picked)" ] && ! sh -c ". \"$WORK/pick.sh\"; pick_release \"$WORK/list.json\"" >/dev/null 2>&1'

sed -n '/^verify_signature()/,/^}/p' scripts/install.sh > "$WORK/verify.sh"
keys=$(sed -n 's/.*let trustedKeys = \(\[.*\]\).*/\1/p' "$WORK/verify.sh")
updater_keys=$(sed -n 's/.*static let trustedKeys = \(\[.*\]\).*/\1/p' Sources/Nimb/Updater.swift)
check "installer trusts exactly the updater public keys" '[ -n "$keys" ] && [ "$keys" = "$updater_keys" ]'

cat > "$WORK/fixtures.swift" <<'SWIFT'
import CryptoKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let other = Curve25519.Signing.PrivateKey()
let data = Data("signed installer regression fixture".utf8)
try data.write(to: folder.appendingPathComponent("archive.zip"))
try Data("changed installer regression fixture".utf8).write(to: folder.appendingPathComponent("changed.zip"))
let signature = try key.signature(for: data)
try Data((signature.base64EncodedString() + "\n").utf8).write(to: folder.appendingPathComponent("archive.sig"))
try Data(signature.prefix(63).base64EncodedString().utf8).write(to: folder.appendingPathComponent("short.sig"))
try Data(try other.signature(for: data).base64EncodedString().utf8).write(to: folder.appendingPathComponent("other.sig"))
try Data("not a signature".utf8).write(to: folder.appendingPathComponent("malformed.sig"))
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: folder.appendingPathComponent("public.txt"))
SWIFT
/usr/bin/swift -module-cache-path "$WORK/swift-cache" "$WORK/fixtures.swift" "$WORK" || exit 1
public=$(cat "$WORK/public.txt")
# No production override for the trust root: substitution exists only in this temporary test copy.
# Use literal-string replacement: the brackets of the public-key array are regular-expression characters.
PUBLIC_KEY="$public" python3 - "$WORK/install-test.sh" "$keys" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(pathlib.Path('scripts/install.sh').read_text().replace(sys.argv[2], '["' + os.environ['PUBLIC_KEY'] + '"]'))
PY
sed -n '/^verify_signature()/,/^}/p' "$WORK/install-test.sh" > "$WORK/verify-test.sh"
. "$WORK/verify-test.sh"
check "a valid author signature is accepted" 'verify_signature "$WORK/archive.zip" "$WORK/archive.sig"'
check "a modified archive is refused" '! verify_signature "$WORK/changed.zip" "$WORK/archive.sig"'
check "a signature of another author is refused" '! verify_signature "$WORK/archive.zip" "$WORK/other.sig"'
check "a truncated signature is refused" '! verify_signature "$WORK/archive.zip" "$WORK/short.sig"'
check "a malformed signature is refused" '! verify_signature "$WORK/archive.zip" "$WORK/malformed.sig"'
check "a missing signature is refused" '! verify_signature "$WORK/archive.zip" "$WORK/missing.sig"'

# Exercise the complete installer through the signature gate. Recompute the hash for the modified archive as an attacker
# controlling the release notes could: a matching checksum must not permit installation without the author's signature.
mkdir -p "$WORK/bin" "$WORK/destination/Nimb.app"
printf 'keep this installation\n' > "$WORK/destination/Nimb.app/original"
cat > "$WORK/bin/curl" <<'SH'
#!/bin/sh
out=""; url=""; next=no
for arg in "$@"; do
    if [ "$next" = yes ]; then out=$arg; next=no; continue; fi
    case "$arg" in -o) next=yes ;; https://*) url=$arg ;; esac
done
case "$url" in
    *releases\?*) cp "$INSTALL_FIXTURES/release.json" "$out" ;;
    *.zip.sig) [ "$INSTALL_CASE" != missing ] || exit 22; cp "$INSTALL_FIXTURES/archive.sig" "$out" ;;
    *.zip) cp "$INSTALL_FIXTURES/changed.zip" "$out" ;;
    *) exit 22 ;;
esac
SH
cat > "$WORK/bin/ditto" <<'SH'
#!/bin/sh
touch "$INSTALL_FIXTURES/unpacked"
exit 1
SH
chmod +x "$WORK/bin/curl" "$WORK/bin/ditto"
hash=$(shasum -a 256 "$WORK/changed.zip" | cut -d' ' -f1)
printf '[{"tag_name":"v0.9.99","draft":false,"prerelease":false,"body":"%s  Nimb-0.9.99.zip","assets":[{"name":"Nimb-0.9.99.zip","browser_download_url":"https://example.test/Nimb-0.9.99.zip"}]}]' "$hash" > "$WORK/release.json"
for scenario in missing changed; do
    if PATH="$WORK/bin:$PATH" INSTALL_FIXTURES="$WORK" INSTALL_CASE="$scenario" NIMB_DEST="$WORK/destination" sh "$WORK/install-test.sh" > "$WORK/installer.log" 2>&1; then
        echo "FAIL: installer accepted $scenario signature"; cat "$WORK/installer.log"; fail=1
    fi
    check "installer rejects $scenario before unpacking or replacing the app" '[ ! -e "$WORK/unpacked" ] && [ "$(cat "$WORK/destination/Nimb.app/original")" = "keep this installation" ] && grep -q "подпись" "$WORK/installer.log"'
done

[ $fail = 0 ] && echo "installer script: all checks passed" || { echo "installer script: FAILED"; exit 1; }
