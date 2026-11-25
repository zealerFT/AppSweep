#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/appsweep-signing.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
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
if env -u DEVELOPER_ID_APPLICATION -u ALLOW_ADHOC_SIGNING \
    OUT_DIR="$FIXTURE/unsigned-output" bash "$ROOT/scripts/build.sh" > "$FIXTURE/result" 2>&1; then
    printf 'FAIL: missing signing identity silently accepted\n' >&2; exit 1
fi
grep -q 'No Developer ID identity provided' "$FIXTURE/result"
[[ ! -e "$FIXTURE/unsigned-output" ]]
printf 'PASS unsigned fallback rejected before creating output\n'
