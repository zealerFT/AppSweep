# Test And QA Runbook

Updated: 2026-09-11.

## Safety Tests

Run `swift run AppSweepSafetyChecks`. The executable exits nonzero on any failed
assertion or unexpected error. Tests use unique, canonicalized temporary roots
and an injected staging Trash adapter, never the user's real applications.

Verified result: 26 checks, 0 failures on the development macOS / Swift 6 toolchain.

Coverage: catalog boundaries, exact bundle IDs, ByHost UUIDs, personal-data defaults,
duplicate copies, protected apps, traversal, candidate/ancestor symlinks, permission
errors, embedded services, structured launch jobs, running apps, stale identities,
late duplicates, case-insensitive bundle identity, selected-only moves, app-last ordering, partial failure, corrupt
or symlinked journals, and invalid/empty selections.

The first test run exposed Foundation's `/private/var` to `/var` rewriting. Trusted
roots now use POSIX realpath, candidate checks use lstat on each component, and
lexical normalization does not silently resolve candidate symlinks.

## Native UI QA

```bash
CONFIGURATION=debug OUT_DIR="$PWD/build/qa-app" bash scripts/build.sh
build/qa-app/AppSweep.app/Contents/MacOS/AppSweep --qa-smoke "$PWD/build/qa" -AppleLanguages '(zh-Hans)'
```

QA loads generated app/Library fixtures, drives the real observable model,
presents native sheets, renders only AppSweep's own content, checks bitmap
color diversity, and writes `build/qa/report.json` plus images. It does not
capture other windows, require Screen Recording permission, grant filesystem
permissions, quit real applications, or use the real system Trash adapter.

Verified result: 15 workflow checks, 7 nonblank images, visually inspected. Desktop
(1100 x 740), minimum window (880 x 620), dark mode, confirmation, permissions,
result and history layouts were checked for clipping, overlap and missing text.
Packaged resource loading is asserted, rather than relying on SwiftPM's absolute
build-directory fallback. App icons in QA are generic because the fixtures are
deliberately non-executable; normal mode uses real installed application icons.

Screen Recording permission is not granted on this Mac. Main-window images use
AppKit view caching. macOS 26 compositor-managed sheet snapshots were blank, so
the test separately verifies actual sheet visibility and renders the same sheet
views in private, offscreen NSHostingViews. These are layout renders, not complete
WindowServer screenshots. The release build excludes the QA implementation.

## Release Checks

```bash
bash -n scripts/build.sh scripts/dmg.sh scripts/release.sh
ARCHS="arm64 x86_64" bash scripts/build.sh
codesign --verify --strict --verbose=2 dist/AppSweep.app
lipo -archs dist/AppSweep.app/Contents/MacOS/AppSweep
bash scripts/dmg.sh
hdiutil verify dist/AppSweep-0.1.0-local-test.dmg
```

Build validation is not equivalent to runtime testing on Intel or macOS 13.
Local packaging evidence: the current architecture release build, ad-hoc code-sign
verification, DMG creation, shell syntax and localization resource validation have
passed. Production signing and notarization remain opt-in and require the
distributor's own credentials.

Production certificates, notarization, quarantine/clean-machine Gatekeeper,
offline installation, real TCC transitions, protected helper removal and
real-application uninstall/recovery tests have not been authorized or verified.
The current release does not implement privileged helper removal.

Before broad release, add controlled disposable-VM tests of the system Trash
adapter and representative supported apps, including failed moves and recovery.
Native model-driven QA does not replace accessibility-driven end-to-end clicks.
