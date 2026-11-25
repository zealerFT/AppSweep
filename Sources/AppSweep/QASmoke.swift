#if DEBUG
import AppKit
import AppSweepCore
import Darwin
import Foundation
import SwiftUI

@MainActor
enum QASmoke {
    private static var fixture: URL?
    private static var output: URL?
    private static var preferencesName: String?
    private static var ran = false

    static func makeModel() -> AppModel? {
        guard let index = CommandLine.arguments.firstIndex(of: "--qa-smoke") else { return nil }
        do {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw QAError.failed("Missing QA output directory")
            }
            defer { free(resolved) }
            let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("AppSweepQA-" + UUID().uuidString)
            fixture = root
            output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let home = root.appendingPathComponent("home")
            let apps = root.appendingPathComponent("Applications")
            for (index, (name, identifier)) in [("Draft Notes", "org.example.DraftNotes"),
                                       ("Pixel Editor", "org.example.PixelEditor"),
                                       ("Studio Player", "org.example.StudioPlayer"),
                                       ("Code Studio", "org.example.CodeStudio")].enumerated() {
                let contents = apps.appendingPathComponent(name + ".app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let info = ["CFBundleIdentifier": identifier, "CFBundleName": name,
                            "CFBundleVersion": "42", "CFBundleShortVersionString": "2.4.1", "CFBundlePackageType": "APPL"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                try Data(repeating: 65, count: (index + 1) * 16_384)
                    .write(to: contents.appendingPathComponent("sample-payload"))
            }
            for (path, bytes) in [
                ("Caches/org.example.DraftNotes/cache", 524_288),
                ("Logs/org.example.DraftNotes/session.log", 8_192),
                ("Preferences/org.example.DraftNotes.plist", 1_024),
                ("Application Support/org.example.DraftNotes/documents/draft.txt", 16_384),
                ("Containers/org.example.DraftNotes/Data/saved", 32_768),
                ("Saved Application State/org.example.DraftNotes.savedState/windows", 4_096),
                ("WebKit/org.example.DraftNotes/data", 65_536),
                ("HTTPStorages/org.example.DraftNotes/cookies", 4_096)
            ] {
                let url = home.appendingPathComponent("Library/" + path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 65, count: bytes).write(to: url)
            }
            let context = ScanContext(home: home, applicationRoots: [apps], serviceRoots: [])
            let suite = "AppSweep.QA." + UUID().uuidString
            preferencesName = suite
            guard let preferences = UserDefaults(suiteName: suite) else { throw QAError.failed("No QA defaults") }
            return AppModel(context: context, historyURL: root.appendingPathComponent("history.json"),
                            trash: QAStagingTrash(root: root.appendingPathComponent("Trash")), preferences: preferences)
        } catch {
            print("QA fixture failed: \(error)")
            exit(1)
        }
    }

    static func run(model: AppModel) async {
        guard let fixture, let output, !ran else { return }
        ran = true
        defer {
            if let preferencesName { UserDefaults.standard.removePersistentDomain(forName: preferencesName) }
        }
        var checks: [String] = []
        var screenshots: [String] = []
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await pause()
            guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) else {
                throw QAError.failed("No main window")
            }
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1100, height: 740))
            try require(AppResources.bundle.bundleURL.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/"),
                        "localizations load from packaged resources, not the build directory", into: &checks)
            try require(model.apps.count == 4, "catalog loads four isolated applications", into: &checks)
            try require(model.showsCompletionDialog, "success dialogs are enabled by default", into: &checks)
            await waitForMetadata(model)
            try require(!model.isLoadingMetadata && model.appMetadata.count == 4,
                        "background catalog metadata finishes for every application", into: &checks)
            model.sortOrder = .largest
            try require(model.filteredApps.first?.name == "Code Studio", "size sort uses measured app bundles", into: &checks)
            model.query = "Pixel"
            try require(model.filteredApps.count == 1, "search filters applications", into: &checks)
            model.query = ""
            guard let app = model.apps.first(where: { $0.name == "Draft Notes" }) else { throw QAError.failed("Fixture not found") }
            model.select(app.id)
            for _ in 0..<100 {
                if !model.isScanning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(model.report?.candidates.count == 9, "scan displays all nine exact matches", into: &checks)
            let firstScanDate = model.report?.scannedAt
            await model.reload()
            // A second refresh cancels old metadata work rather than leaving stale rows.
            await model.reload()
            await waitForMetadata(model)
            try require(Set(model.appMetadata.keys) == Set(model.apps.map(\.id)),
                        "refresh replaces metadata without stale entries", into: &checks)
            // Controlled dates represent documented fictional app use in the layout fixtures.
            for (index, app) in model.apps.enumerated() {
                let date = app.name == "Code Studio" ? nil : Date().addingTimeInterval(-Double((index + 1) * 30 * 86_400))
                model.appMetadata[app.id] = ApplicationMetadata(size: model.appMetadata[app.id]?.size, lastUsed: date)
            }
            model.sortOrder = .leastRecentlyUsed
            try require(model.filteredApps.last?.name == "Code Studio",
                        "apps without usage records stay below dated applications", into: &checks)
            for _ in 0..<100 {
                if !model.isScanning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(model.report?.scannedAt != firstScanDate,
                        "toolbar refresh rescans the selected application", into: &checks)
            try require(model.chosen.count == 3 && model.chosen.allSatisfy { !$0.kind.containsUserData },
                        "default selection excludes personal data", into: &checks)
            try await pause()
            try capture(window, to: output, name: "desktop.png", names: &screenshots)
            window.setContentSize(NSSize(width: 880, height: 620))
            try await pause()
            try capture(window, to: output, name: "compact.png", names: &screenshots)
            window.appearance = NSAppearance(named: .darkAqua)
            try await pause()
            try capture(window, to: output, name: "dark.png", names: &screenshots)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1100, height: 740))
            if let data = model.report?.candidates.first(where: { $0.kind == .applicationData }) {
                model.selectedCandidates.insert(data.id)
                try require(model.chosen.count == 4, "candidate checkbox binding updates selection", into: &checks)
            }
            model.showConfirmation = true
            try await pause()
            guard let sheet = window.attachedSheet else { throw QAError.failed("Confirmation sheet not presented") }
            try require(sheet.isVisible, "native confirmation sheet is visible", into: &checks)
            try render(ConfirmationView(appName: app.name, items: model.chosen,
                                        size: model.chosenSize, hasScanIssues: false, confirm: {}),
                       size: NSSize(width: 510, height: 550), to: output, name: "confirmation.png", names: &screenshots)
            model.showConfirmation = false
            try await pause()
            model.showPermissions = true
            try await pause()
            guard let permissionSheet = window.attachedSheet else { throw QAError.failed("Permissions sheet not presented") }
            try require(permissionSheet.isVisible, "native permission sheet is visible", into: &checks)
            try render(PermissionsView(issues: [], rescan: {}), size: NSSize(width: 540, height: 560),
                       to: output, name: "permissions.png", names: &screenshots)
            model.showPermissions = false
            try await pause()
            model.selectedCandidates = Set(model.report!.candidates.filter { $0.kind.selectedByDefault }.map(\.id))
            await model.removeSelection()
            try require(model.result?.succeeded == true, "confirmed removal succeeds in isolated staging trash", into: &checks)
            try require(model.apps.count == 3, "application list refreshes after removal", into: &checks)
            try require(model.history.first?.trashedCount == 3, "history contains per-file results", into: &checks)
            try require(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("home/Library/Application Support/org.example.DraftNotes/documents/draft.txt").path),
                        "unselected personal document survives", into: &checks)
            try await pause()
            if let resultSheet = window.attachedSheet, let record = model.result {
                try require(resultSheet.isVisible, "native result sheet is visible", into: &checks)
                try render(ResultView(record: record, suppressSuccessDialog: .constant(false), close: {}, viewHistory: {}),
                           size: NSSize(width: 460, height: 380),
                           to: output, name: "result.png", names: &screenshots)
            }
            model.showsCompletionDialog = false
            model.dismissResult()
            try await pause()
            try require(model.result == nil && model.section == .applications && window.attachedSheet == nil,
                        "closing the result sheet stays in the application list", into: &checks)
            guard let preferencesName, let savedPreferences = UserDefaults(suiteName: preferencesName) else {
                throw QAError.failed("QA preference suite missing")
            }
            let reopened = AppModel(context: model.context, historyURL: fixture.appendingPathComponent("history.json"),
                                    trash: QAStagingTrash(root: fixture.appendingPathComponent("Trash")), preferences: savedPreferences)
            try require(!reopened.showsCompletionDialog && reopened.sortOrder == .leastRecentlyUsed,
                        "dialog and sort preferences survive model recreation", into: &checks)
            guard let nextApp = model.apps.first(where: { $0.name == "Pixel Editor" }) else {
                throw QAError.failed("Second cleanup fixture missing")
            }
            model.select(nextApp.id)
            for _ in 0..<100 {
                if !model.isScanning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            await model.removeSelection()
            try await pause()
            try require(model.result == nil && window.attachedSheet == nil && model.completionNotice != nil,
                        "suppressed success uses a non-modal notice", into: &checks)
            try require(model.history.count == 2 && model.history.first?.succeeded == true,
                        "suppressed success still saves complete operation history", into: &checks)
            guard var failed = model.history.first else { throw QAError.failed("Missing second result") }
            failed.entries[0].status = .failed
            failed.entries[0].trashPath = nil
            failed.entries[0].error = "Isolated QA permission failure"
            failed.entries[0].failure = RemovalFailure(CocoaError(.fileWriteNoPermission))
            model.presentResult(failed)
            try await pause()
            try require(model.result?.succeeded == false && window.attachedSheet != nil,
                        "failed cleanup still displays a result when success prompts are disabled", into: &checks)
            try render(ResultView(record: failed, suppressSuccessDialog: .constant(false), close: {}, viewHistory: {}),
                       size: NSSize(width: 460, height: 540), to: output, name: "permission-failure.png", names: &screenshots)
            model.dismissResult()
            try await pause()
            var journalFailure = model.history[0]
            journalFailure.journalError = "Isolated QA journal failure"
            model.presentResult(journalFailure)
            try require(model.result?.journalError != nil, "journal failures cannot be suppressed", into: &checks)
            model.dismissResult()
            try await pause()
            model.showsCompletionDialog = true
            model.presentResult(model.history[0])
            try require(model.result?.succeeded == true, "turning success prompts back on restores the dialog", into: &checks)
            model.viewResultHistory()
            try require(model.result == nil && model.section == .history,
                        "history opens only when explicitly requested", into: &checks)
            try await pause()
            try capture(window, to: output, name: "history.png", names: &screenshots)
            // Exercise the real system recycle callback with one disposable
            // fixture, then bring it back so no test app is left in Trash.
            let probe = fixture.appendingPathComponent("SystemRecycleProbe.app")
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
            let probeIdentity = try FileIdentity.read(probe)
            guard let destination = try await SystemTrash().moveToTrash(probe) else {
                throw QAError.failed("System recycle returned no destination")
            }
            try require(!FileManager.default.fileExists(atPath: probe.path)
                        && (try FileIdentity.read(destination)) == probeIdentity,
                        "system recycle returns the actual Trash destination for a disposable fixture", into: &checks)
            try FileManager.default.moveItem(at: destination, to: probe)
            let result = QAReport(checks: checks, screenshots: screenshots, failure: nil)
            try JSONEncoder().encode(result).write(to: output.appendingPathComponent("report.json"), options: .atomic)
            print("QA PASS: \(checks.count) workflow checks; \(screenshots.count) nonblank native screenshots; no real applications touched.")
            try FileManager.default.removeItem(at: fixture)
            NSApplication.shared.terminate(nil)
        } catch {
            print("QA FAIL: \(error)")
            let result = QAReport(checks: checks, screenshots: screenshots, failure: String(describing: error))
            try? JSONEncoder().encode(result).write(to: output.appendingPathComponent("report.json"), options: .atomic)
            try? FileManager.default.removeItem(at: fixture)
            exit(1)
        }
    }

    private static func pause() async throws { try await Task.sleep(for: .milliseconds(650)) }

    private static func waitForMetadata(_ model: AppModel) async {
        for _ in 0..<100 {
            if !model.isLoadingMetadata { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func require(_ condition: Bool, _ description: String, into checks: inout [String]) throws {
        guard condition else { throw QAError.failed(description) }
        checks.append(description)
    }

    private static func capture(_ window: NSWindow, to output: URL, name: String, names: inout [String]) throws {
        guard let view = window.contentView else { throw QAError.failed("No content view") }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QAError.failed("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 13) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 13) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        guard colors.count > 15, let data = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Blank screenshot: " + name)
        }
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        names.append(name)
    }

    private static func render<V: View>(_ content: V, size: NSSize, to output: URL,
                                       name: String, names: inout [String]) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try capture(window, to: output, name: name, names: &names)
    }
}

private enum QAError: Error { case failed(String) }
private struct QAReport: Codable {
    let checks: [String]
    let screenshots: [String]
    let failure: String?
}
private struct QAStagingTrash: TrashMoving {
    let root: URL
    func moveToTrash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
#endif
