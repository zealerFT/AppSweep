# Tech Stack

Updated: 2026-11-24.

| Category | Choice | Evidence |
| --- | --- | --- |
| Platform | macOS 13+, Apple Silicon and Intel build targets | Package.swift |
| Language | Swift 6 | Package.swift |
| UI | SwiftUI, AppKit, native SF Symbols and installed app icons | Sources/AppSweep |
| Core | Foundation, Darwin file identity APIs, CoreServices Spotlight metadata | Sources/AppSweepCore |
| Storage | Local Codable JSON history; UserDefaults for UI preferences | HistoryStore, AppModel |
| Build | Swift Package Manager + app bundle scripts | Package.swift, scripts/ |
| Tests | Standalone Swift assertion runner, isolated fixtures | Tests/, Package.swift |
| Distribution | DMG; Developer ID and notarization for production | scripts/ |
| Dependencies | No third-party dependencies or services | Package.swift |

Do not introduce Electron, web servers, databases, shell-based deletion, privileged
helpers or auto-updaters without a separate decision and authorization.

Published bundle ID: `io.github.zealerft.AppSweep` (`.github/workflows/release.yml`).
Unknown: Developer ID identity, Apple team/account,
notary keychain profile, minimum-OS hardware QA coverage.
