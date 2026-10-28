#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${DEVELOPER_ID_APPLICATION:?Set your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set the name of a notarytool keychain profile}"
: "${APP_BUNDLE_ID:?Set your own stable reverse-DNS application identifier}"
[[ "$APP_BUNDLE_ID" != com.example.* ]] || { printf 'Replace the example bundle ID before release.\n' >&2; exit 1; }
export ARCHS="arm64 x86_64"
export CONFIGURATION=release
export OUT_DIR="${OUT_DIR:-$ROOT/dist/release}"
export APP_VERSION="${APP_VERSION:-0.1.0}"
export DMG_NAME="AppSweep-$APP_VERSION-universal.dmg"
bash "$ROOT/scripts/build.sh"
bash "$ROOT/scripts/dmg.sh"
DMG="$OUT_DIR/$DMG_NAME"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$OUT_DIR/notarization.json"
STATUS="$(plutil -extract status raw -o - "$OUT_DIR/notarization.json")"
[[ "$STATUS" == Accepted ]] || { printf 'Notarization failed; inspect %s/notarization.json\n' "$OUT_DIR" >&2; exit 1; }
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
printf '\nNotarized distribution image: %s\n' "$DMG"
