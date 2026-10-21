#!/bin/sh
# Checks of the choice of the release in scripts/install.sh: it must take the newest release for the Mac, whatever else is in the list
# (a release of the Windows version, a pre-release, a draft). No network: the lists are written here.
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

[ $fail = 0 ] && echo "installer script: all checks passed" || { echo "installer script: FAILED"; exit 1; }
