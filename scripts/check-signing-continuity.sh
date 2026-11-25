#!/bin/bash
set -euo pipefail

[[ $# -eq 2 ]] || { printf 'Usage: check-signing-continuity.sh previous.app candidate.app\n' >&2; exit 2; }
PREVIOUS_APP="$1"
CANDIDATE_APP="$2"
for app in "$PREVIOUS_APP" "$CANDIDATE_APP"; do
    [[ -d "$app" ]] || { printf 'Application bundle is missing.\n' >&2; exit 1; }
    codesign --verify --strict "$app"
done
previous_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PREVIOUS_APP/Contents/Info.plist")"
candidate_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CANDIDATE_APP/Contents/Info.plist")"
[[ "$previous_id" == "$candidate_id" ]] || { printf 'Bundle identity changed; refusing an in-place update.\n' >&2; exit 1; }
requirement="$(codesign -d -r- "$PREVIOUS_APP" 2>&1 | sed -n 's/^#* *designated => //p')"
[[ -n "$requirement" ]] || { printf 'Cannot verify the previous signing requirement.\n' >&2; exit 1; }
if ! codesign --verify --strict -R="$requirement" "$CANDIDATE_APP"; then
    printf 'Signing identity changed. This update can invalidate macOS privacy grants even when switches remain enabled.\nRebuild with the same signing identity; the existing application has not been replaced.\n' >&2
    exit 1
fi
printf 'Signing continuity verified.\n'
