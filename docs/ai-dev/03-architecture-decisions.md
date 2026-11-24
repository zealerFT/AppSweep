# Architecture Decisions

## ADR-20261124-001: Cleanup Prioritization And Remembered Success Prompts

- Status: accepted, within the existing native stack; no external dependency.
- User request: sort by app size and last use; allow closing the result dialog and
  remember the choice not to show it again.
- Decision: measure app-bundle allocated bytes in cancellable background tasks;
  read `kMDItemLastUsedDate` through CoreServices. Do not substitute file access,
  modification or installation dates for actual use. Unknown values sort last.
- Store sort order and success-dialog preference in local UserDefaults. Keep
  failure dialogs visible and expose a setting to restore success prompts.
- The existing scan, explicit removal confirmation and history remain the
  authoritative removal workflow; sorting metadata is informational only.
- Tests: numeric/date ordering, missing metadata, bounded and symlink-safe size
  measurements, preference persistence, dialog dismissal without navigation,
  suppressed success with history retained, and visible failure results.
- Evidence: Sources/AppSweepCore, AppModel, ContentView, OperationViews, QASmoke.

## ADR-20260911-001: Native, Conservative Standalone Uninstaller

- Status: accepted.
- User confirmation: native SwiftUI/AppKit app and standalone DMG distribution.
- Decision: SwiftPM builds the native application and testable core without an
  Xcode-project generator. Bundle scripts package it for local testing and later
  Developer ID distribution.
- Alternatives: Electron adds an unnecessary runtime; App Store sandboxing does
  not fit general uninstallation; privileged helper adds avoidable first-release risk.
- Scope: current-user residual data, known application roots, explicit-ID evidence.
- No name matching, blanket Library deletion, bypassing Gatekeeper/SIP, automatic
  privilege escalation, or "all remnants removed" claims.
- Rollback: all successful removals use system Trash; history reveals the resulting
  locations. Restore is performed through Finder, not an automatic overwrite.
- Tests: exact matches, permissions/error reporting, duplicate IDs, path traversal,
  symlinks, changed identities, running apps, journal and partial-failure behavior.

## ADR-20260911-002: Toolchain-Compatible Safety Checks

- Status: accepted implementation adaptation within the approved native Swift stack.
- Evidence: local `swift test` fails because Command Line Tools has no XCTest;
  `swift -e 'import Testing'` also fails. The GUI builds successfully.
- Decision: run isolated tests as `swift run AppSweepSafetyChecks`, using a small
  assertion/exit-status runner without adding packages or global tools.
- Impact: no XCTest discovery; new checks must be registered in TestRunner.swift.
- Migration: a future full-Xcode CI setup may adopt XCTest without changing core
  runtime behavior or test fixtures.
