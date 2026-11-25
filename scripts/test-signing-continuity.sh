#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/appsweep-signing.XXXXXX")"
cleanup() {
    if [[ -f "$FIXTURE/signing/identity.keychain-db" ]]; then
        security delete-keychain "$FIXTURE/signing/identity.keychain-db" >/dev/null 2>&1 || true
    fi
    rm -rf "$FIXTURE"
}
trap cleanup EXIT
mkdir -p "$FIXTURE/fixtures.noindex/old.app/Contents/MacOS"
OLD="$FIXTURE/fixtures.noindex/old.app"
NEW="$FIXTURE/fixtures.noindex/new.app"
cat > "$FIXTURE/main.c" <<'C'
int main(void) { return 0; }
C
xcrun clang "$FIXTURE/main.c" -o "$OLD/Contents/MacOS/fixture"
cat > "$OLD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.SigningFixture</string>
<key>CFBundleExecutable</key><string>fixture</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$OLD"
bash "$ROOT/scripts/check-signing-continuity.sh" "$OLD" "$OLD"
ditto "$OLD" "$NEW"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$NEW/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$NEW"
if bash "$ROOT/scripts/check-signing-continuity.sh" "$OLD" "$NEW" > "$FIXTURE/result" 2>&1; then
    printf 'FAIL: changed ad-hoc signature was accepted\n' >&2; exit 1
fi
grep -q 'Signing identity changed' "$FIXTURE/result"
printf 'PASS changed ad-hoc identity rejected\n'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.example.Other' "$NEW/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$NEW"
if bash "$ROOT/scripts/check-signing-continuity.sh" "$OLD" "$NEW" > "$FIXTURE/result" 2>&1; then
    printf 'FAIL: changed bundle identifier was accepted\n' >&2; exit 1
fi
grep -q 'Bundle identity changed' "$FIXTURE/result"
printf 'PASS changed bundle identity rejected\n'
if env -u ALLOW_ADHOC_SIGNING DEVELOPER_ID_APPLICATION=invalid-identity \
    OUT_DIR="$FIXTURE/unsigned-output" bash "$ROOT/scripts/build.sh" > "$FIXTURE/result" 2>&1; then
    printf 'FAIL: invalid explicit distribution identity silently accepted\n' >&2; exit 1
fi
grep -q 'A Developer ID Application identity is required' "$FIXTURE/result"
[[ ! -e "$FIXTURE/unsigned-output" ]]
printf 'PASS invalid distribution identity rejected before creating output\n'

# Exercise the personal-use path with an isolated identity, not the user's
# persistent signer. A version change must change the binary's signature hash
# while retaining the same cryptographic signing requirement.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.example.SigningFixture' "$NEW/Contents/Info.plist"
security list-keychains -d user > "$FIXTURE/search-before"
python3 "$ROOT/scripts/local-sign.py" --state-dir "$FIXTURE/signing" "$OLD"
python3 "$ROOT/scripts/local-sign.py" --state-dir "$FIXTURE/signing" "$NEW"
bash "$ROOT/scripts/check-signing-continuity.sh" "$OLD" "$NEW"
old_hash="$(codesign -d --verbose=4 "$OLD" 2>&1 | sed -n 's/^CDHash=//p')"
new_hash="$(codesign -d --verbose=4 "$NEW" 2>&1 | sed -n 's/^CDHash=//p')"
[[ -n "$old_hash" && -n "$new_hash" && "$old_hash" != "$new_hash" ]]
security list-keychains -d user > "$FIXTURE/search-after"
cmp "$FIXTURE/search-before" "$FIXTURE/search-after"
mv "$FIXTURE/signing/keychain-password" "$FIXTURE/saved-password"
if python3 "$ROOT/scripts/local-sign.py" --state-dir "$FIXTURE/signing" "$NEW" > "$FIXTURE/result" 2>&1; then
    printf 'FAIL: incomplete signing state was silently replaced\n' >&2; exit 1
fi
[[ ! -e "$FIXTURE/signing/keychain-password" ]]
mv "$FIXTURE/saved-password" "$FIXTURE/signing/keychain-password"
security delete-keychain "$FIXTURE/signing/identity.keychain-db"
printf 'PASS different local builds retain signing identity without an Apple account\n'
printf 'PASS build keychain search entry removed after signing\n'
printf 'PASS incomplete local identity is preserved instead of regenerated\n'
