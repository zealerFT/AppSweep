# Project Architecture

Updated: 2026-09-11. New, independent macOS desktop application.

## Boundaries

| Module | Responsibility | Constraints |
| --- | --- | --- |
| AppSweepCore | Catalog, exact-ID scan policy, identity checks, removal journal | No shell deletion, no elevation, no network |
| AppSweep | SwiftUI/AppKit UI, app icons, running-app checks, permission links | Explicit confirmation before every removal |
| scripts | Local app/DMG assembly; opt-in signing and notarization | Never alter system security settings |
| Tests | Isolated temporary app/Library fixtures and fake trash | Never uninstall a user's installed application |

## Data Flow

Catalog -> selected app -> immutable scan report -> user selection -> fresh scan
and identity validation -> persisted operation plan -> per-item Trash operation ->
per-item persisted result. The application bundle is moved last. Any failure stops
remaining moves. Partial results stay visible.

## Safety Policy

- Application roots: /Applications and ~/Applications; no system applications.
- Only explicit bundle-ID paths in the current user's Library are candidates.
- Never infer ownership from a display name or vendor prefix.
- Personal data and preferences are not selected by default.
- No shared Group Containers, external volumes, drivers, or privileged deletion.
- Duplicate installed bundle IDs block shared data removal.
- Symlink paths, stale file identities, self-uninstall and Apple bundle IDs are blocked.
- Embedded services/extensions and positively matched launch jobs require the
  application's official uninstaller. Detection is conservative, not exhaustive.
- Missing permissions and bounded/incomplete size estimates are visible.
- Moving to Trash does not reclaim disk space until the user empties Trash.

## State And Storage

One main-actor observable UI model; background scan tasks and a serialized removal
actor. Local JSON history under ~/Library/Application Support/<bundle-id>/.
No analytics, backend, cloud sync, auto-update, or privileged helper in this version.

Evidence: Package.swift, Sources/ and the selected standalone-distribution
workflow. Release identity and signing account remain user-supplied. Future
dependencies or safety-scope changes require an ADR.
