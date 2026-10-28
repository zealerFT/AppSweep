#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.example.AppSweep}"
APP_VERSION="${APP_VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || { printf 'Invalid configuration\n' >&2; exit 1; }
[[ "$APP_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { printf 'Invalid bundle ID\n' >&2; exit 1; }
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid version\n' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { printf 'Invalid build number\n' >&2; exit 1; }
mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d "$OUT_DIR/.appsweep-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AppSweep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINARIES=()
RESOURCE_SOURCE=""
for arch in $ARCHS; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1; }
    swift build --package-path "$ROOT" --scratch-path "$ROOT/.build/$arch" \
        --configuration "$CONFIGURATION" --triple "$arch-apple-macosx13.0" --product AppSweep
    BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$ROOT/.build/$arch" \
        --configuration "$CONFIGURATION" --triple "$arch-apple-macosx13.0" --show-bin-path)"
    BINARIES+=("$BIN_DIR/AppSweep")
    RESOURCE_SOURCE="$BIN_DIR/AppSweep_AppSweep.bundle"
done
[[ ${#BINARIES[@]} -gt 0 ]] || { printf 'ARCHS is empty\n' >&2; exit 1; }
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/AppSweep"
else
    xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/AppSweep"
fi
ditto "$RESOURCE_SOURCE" "$APP/Contents/Resources/AppSweep_AppSweep.bundle"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
swift "$ROOT/scripts/make-icon.swift" "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    [[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application:'* ]] || { printf 'A Developer ID Application identity is required\n' >&2; exit 1; }
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
else
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
if [[ -e "$OUT_DIR/AppSweep.app" ]]; then
    mv "$OUT_DIR/AppSweep.app" "$STAGE/previous-build.app"
fi
mv "$APP" "$OUT_DIR/AppSweep.app"
printf '\nBuilt: %s/AppSweep.app\n' "$OUT_DIR"
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf 'LOCAL TEST BUILD: ad-hoc signed, not notarized, not a production release.\n'
fi
