# Local Environment Runbook

Updated: 2026-09-11. Scope: local development only.

- Project: repository root; build commands are independent of the caller's parent directory.
- Host: macOS 26.5.2 (25F84), Apple Silicon.
- Active developer directory: /Library/Developer/CommandLineTools.
- Swift: 6.3.2, swiftlang-6.3.2.1.108.
- Available: SwiftPM, macOS SDK, lipo, codesign, hdiutil, iconutil, notarytool.
- Not available in this toolchain: XCTest and Swift Testing modules.
- No external packages, servers, open ports, databases, containers, VPN or credentials required for local build/tests.

## Commands

```bash
swift run AppSweepSafetyChecks
bash scripts/build.sh
open dist/AppSweep.app
bash scripts/dmg.sh
```

`CONFIGURATION=debug` includes fixture-only native QA. `ARCHS="arm64 x86_64"`
builds both targets and uses lipo. Build output replaces only the generated
AppSweep.app in OUT_DIR. Temporary build/DMG staging folders are private and
removed by each script's EXIT trap.

## Release Inputs

| Variable | Requirement | Secret? |
| --- | --- | --- |
| APP_BUNDLE_ID | User-owned stable reverse-DNS identifier | No |
| APP_VERSION / BUILD_NUMBER | Release version/build | No |
| DEVELOPER_ID_APPLICATION | Installed Developer ID identity name | No; associated private key remains in Keychain |
| NOTARY_PROFILE | Existing notarytool Keychain profile name | No; credentials remain in Keychain |
| OUT_DIR | Optional generated output directory | No |

Do not enumerate/export private keys or write signing credentials into files.
Do not disable Gatekeeper/SIP, reset TCC, grant permissions with scripts, or
install privileged helpers. Do not run real uninstalls as development probes.

## Unknowns

Production signing identity, Apple team, final bundle ID, notarization profile,
real Intel and minimum-OS hardware, and public distribution channel require
user confirmation. The release script must remain opt-in.
