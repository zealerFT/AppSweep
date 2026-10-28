#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
APP="$OUT_DIR/AppSweep.app"
[[ -d "$APP" ]] || { printf 'Run bash scripts/build.sh first.\n' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="${DMG_NAME:-AppSweep-$VERSION-local-test.dmg}"
[[ "$NAME" != */* && "$NAME" == *.dmg ]] || { printf 'DMG_NAME must be a filename ending in .dmg\n' >&2; exit 1; }
STAGE="$(mktemp -d "$OUT_DIR/.appsweep-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/AppSweep.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname AppSweep -srcfolder "$STAGE" -ov -format UDZO "$OUT_DIR/$NAME"
printf '\nDMG: %s/%s\n' "$OUT_DIR" "$NAME"
