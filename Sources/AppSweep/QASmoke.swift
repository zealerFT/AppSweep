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
            for (name, identifier) in [("Draft Notes", "org.example.DraftNotes"),
                                       ("Pixel Editor", "org.example.PixelEditor"),
                                       ("Studio Player", "org.example.StudioPlayer"),
                                       ("Code Studio", "org.example.CodeStudio")] {
                let contents = apps.appendingPathComponent(name + ".app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let info = ["CFBundleIdentifier": identifier, "CFBundleName": name,
                            "CFBundleVersion": "42", "CFBundleShortVersionString": "2.4.1", "CFBundlePackageType": "APPL"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
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
            return AppModel(context: context, historyURL: root.appendingPathComponent("history.json"),
                            trash: QAStagingTrash(root: root.appendingPathComponent("Trash")))
        } catch {
            print("QA fixture failed: \(error)")
            exit(1)
        }
    }

    static func run(model: AppModel) async {
        guard let fixture, let output, !ran else { return }
        ran = true
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
            try render(PermissionsView(issues: [], rescan: {}), size: NSSize(width: 540, height: 390),
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
                try render(ResultView(record: record, viewHistory: {}), size: NSSize(width: 460, height: 300),
                           to: output, name: "result.png", names: &screenshots)
            }
            model.result = nil
            model.section = .history
            try await pause()
            try capture(window, to: output, name: "history.png", names: &screenshots)
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
