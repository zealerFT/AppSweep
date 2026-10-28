import Foundation
import Darwin
import AppSweepCore

final class AppSweepCoreTests: @unchecked Sendable {
    func testCatalogIncludesNestedAppsButNotTheirHelpersOrSymlinks() throws {
        let f = try Fixture(); defer { f.clean() }
        let one = try f.app("Notebook")
        let two = try f.app("Tools/Editor", identifier: "org.example.Editor")
        _ = try f.app("Notebook.app/Contents/Helper", identifier: "org.example.Helper")
        try FileManager.default.createSymbolicLink(at: f.apps.appendingPathComponent("Alias.app"), withDestinationURL: one.url)
        expectEqual(Set(try f.scanner.catalog().applications.map(\.id)), [one.id, two.id])
    }

    func testInvalidApplicationPackagesAreInformational() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.app("Notebook")
        let invalid = f.apps.appendingPathComponent("Broken.app")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)

        let issues = try f.scanner.catalog().issues.filter { $0.path == invalid.path }
        expectEqual(issues.map(\.kind), [.invalidApplication])
        expectFalse(issues.contains { $0.kind == .inaccessible })
        expectFalse(ScanIssueKind.invalidApplication.isActionable)
    }

    func testOnlyExactBundleIDPathsAreCandidates() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let cache = try f.file("Caches/org.example.Notebook/item")
        let prefs = try f.file("Preferences/org.example.Notebook.plist")
        _ = try f.file("Caches/org.example.NotebookHelper/item")
        _ = try f.file("Application Support/Notebook/document")
        _ = try f.file("Application Support/org.example/document")
        _ = try f.file("Group Containers/org.example.Notebook/document")
        let report = try f.scan(app)
        expectEqual(Set(report.candidates.map(\.id)), [app.id, cache.deletingLastPathComponent().path, prefs.path])
        expectTrue(report.candidates.allSatisfy(\.canSelect))
    }

    func testPersonalDataIsNeverSelectedByDefault() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        _ = try f.file("Application Support/org.example.Notebook/document")
        _ = try f.file("Containers/org.example.Notebook/document")
        _ = try f.file("Saved Application State/org.example.Notebook.savedState/state")
        _ = try f.file("Preferences/org.example.Notebook.plist")
        let report = try f.scan(app)
        expectEqual(report.candidates.filter { $0.kind.selectedByDefault }.map(\.kind), [.application])
        expectTrue(report.candidates.filter { $0.kind != .application }.allSatisfy { $0.kind.containsUserData })
    }

    func testByHostRequiresAnExactIdentifierAndUUID() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let exact = try f.file("Preferences/ByHost/org.example.Notebook.\(UUID().uuidString).plist")
        _ = try f.file("Preferences/ByHost/org.example.Notebook.other.plist")
        _ = try f.file("Preferences/ByHost/org.example.NotebookExtra.\(UUID().uuidString).plist")
        expectEqual(try f.scan(app).candidates.filter { $0.kind == .preferences }.map(\.id), [exact.path])
    }

    func testDuplicateCopiesBlockAllResidualData() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        _ = try f.app("Second Copy")
        _ = try f.file("Caches/org.example.Notebook/data")
        let report = try f.scan(app)
        expectNil(report.candidates.first { $0.kind == .application }?.blockReason)
        expectEqual(report.candidates.first { $0.kind == .cache }?.blockReason, .sharedIdentifier)
        expectTrue(report.issues.contains { $0.kind == .sharedIdentifier })
    }

    func testAppleAndSelfApplicationsAreProtected() throws {
        let f = try Fixture(); defer { f.clean() }
        for (name, identifier) in [("Self", "com.example.AppSweep"), ("System", "com.apple.Test"),
                                   ("Uppercase self", "COM.EXAMPLE.APPSWEEP"), ("Uppercase system", "COM.APPLE.TEST")] {
            let app = try f.app(name, identifier: identifier)
            expectEqual(try f.scan(app).candidates.first?.blockReason, .protectedApplication)
        }
    }

    func testCaseVariantsShareBundleIdentity() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        _ = try f.app("Case Variant", identifier: "ORG.EXAMPLE.NOTEBOOK")
        _ = try f.file("Caches/org.example.Notebook/data")
        expectEqual(try f.scan(app).candidates.first { $0.kind == .cache }?.blockReason, .sharedIdentifier)
    }

    func testBundleIdentifierRejectsPathTraversal() throws {
        let f = try Fixture(); defer { f.clean() }
        for id in ["../Caches", "org.example/../../file", ".hidden", "org..example", "org.example.", "org\\example", ""] {
            do {
                _ = try f.app(UUID().uuidString, identifier: id)
                fail("Accepted invalid identifier: " + id)
            } catch { }
        }
        _ = try f.app(identifier: "org.example.My-App_2")
    }

    func testApplicationPathCannotEscapeRootsOrEnterAnotherApp() throws {
        let f = try Fixture(); defer { f.clean() }
        expectFalse(f.context.permitsApplicationPath(f.root.appendingPathComponent("ApplicationsExtra/Other.app")))
        expectFalse(f.context.permitsApplicationPath(f.apps.appendingPathComponent("Parent.app/Contents/Child.app")))
        expectFalse(f.context.permitsApplicationPath(f.apps.appendingPathComponent("../Other.app")))
    }

    func testSymlinkCandidateIsBlockedAndNotFollowed() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let outside = try f.file("Important/document")
        let link = f.home.appendingPathComponent("Library/Caches/org.example.Notebook")
        try f.makeParent(link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        let candidate = try requireValue(f.scan(app).candidates.first { $0.kind == .cache })
        expectEqual(candidate.blockReason, .unsafePath)
        expectEqual(candidate.size.bytes, 0)
        expectTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSymlinkLibraryRootIsReportedAndSkipped() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let elsewhere = try f.file("Elsewhere/org.example.Notebook/data").deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent("Library/Caches"), withDestinationURL: elsewhere)
        let report = try f.scan(app)
        expectFalse(report.candidates.contains { $0.kind == .cache })
        expectTrue(report.issues.contains { $0.kind == .unsafePath })
    }

    func testUnreadableDirectoryIsNotReportedAsNoRemnants() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let file = try f.file("Caches/org.example.Notebook/data")
        let directory = file.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let report = try f.scan(app)
        expectTrue(report.issues.contains { $0.kind == .inaccessible && $0.path == directory.path })
    }

    func testEmbeddedServiceRequiresOfficialUninstaller() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let helper = app.url.appendingPathComponent("Contents/Library/LaunchServices/helper")
        try f.makeParent(helper)
        try Data("helper".utf8).write(to: helper)
        expectTrue(try f.scan(app).candidates.allSatisfy { $0.blockReason == .officialUninstaller })
    }

    func testLaunchJobIsMatchedByStructuredProgramPath() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let job = f.context.serviceRoots[0].appendingPathComponent("different-label.plist")
        try f.makeParent(job)
        try f.writePlist(["Label": "other.service", "ProgramArguments": [app.url.path + "/Contents/MacOS/Notebook"]], at: job)
        expectTrue(try f.scan(app).issues.contains { $0.kind == .officialUninstaller && $0.path == job.path })
    }

    func testUnrelatedLaunchJobDoesNotBlockApplication() throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let job = f.context.serviceRoots[0].appendingPathComponent("unrelated.plist")
        try f.makeParent(job)
        try f.writePlist(["Label": "org.example.NotebookExtra", "Program": "/usr/bin/true"], at: job)
        expectTrue(try f.scan(app).candidates.allSatisfy(\.canSelect))
    }

    func testRunningApplicationPreventsAllMoves() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let report = try f.scan(app)
        do {
            _ = try await f.removal().remove(report: report, selectedIDs: [app.id], isRunning: { _ in true })
            fail("Expected running application error")
        } catch SweepError.runningApplication { }
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
        expectFalse(FileManager.default.fileExists(atPath: f.historyURL.path))
    }

    func testChangedFileIdentityPreventsRemoval() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let cache = try f.file("Caches/org.example.Notebook/data").deletingLastPathComponent()
        let report = try f.scan(app)
        try FileManager.default.moveItem(at: cache, to: cache.appendingPathExtension("old"))
        _ = try f.file("Caches/org.example.Notebook/new")
        do {
            _ = try await f.removal().remove(report: report, selectedIDs: [cache.path], isRunning: { _ in false })
            fail("Expected stale selection error")
        } catch SweepError.selectionChanged { }
        expectTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testNewDuplicateAfterScanPreventsDataRemoval() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let cache = try f.file("Caches/org.example.Notebook/data").deletingLastPathComponent()
        let report = try f.scan(app)
        _ = try f.app("New copy")
        do {
            _ = try await f.removal().remove(report: report, selectedIDs: [cache.path], isRunning: { _ in false })
            fail("Expected ownership revalidation")
        } catch SweepError.selectionChanged { }
        expectTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testOnlySelectedItemsMoveAndHistoryIsSaved() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let cache = try f.file("Caches/org.example.Notebook/data").deletingLastPathComponent()
        let document = try f.file("Application Support/org.example.Notebook/document")
        let record = try await f.removal().remove(report: f.scan(app), selectedIDs: [app.id, cache.path], isRunning: { _ in false })
        expectTrue(record.succeeded)
        expectEqual(record.entries.last?.originalPath, app.id)
        expectFalse(FileManager.default.fileExists(atPath: app.url.path))
        expectFalse(FileManager.default.fileExists(atPath: cache.path))
        expectTrue(FileManager.default.fileExists(atPath: document.path))
        for entry in record.entries { expectTrue(FileManager.default.fileExists(atPath: try requireValue(entry.trashPath))) }
        let saved = try await HistoryStore(url: f.historyURL).load()
        expectEqual(saved.first?.trashedCount, 2)
        expectEqual(saved.first?.id, record.id)
    }

    func testTrashFailureStopsBeforeMovingAppAndRecordsPartialResult() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let cache = try f.file("Caches/org.example.Notebook/data").deletingLastPathComponent()
        let logs = try f.file("Logs/org.example.Notebook/log").deletingLastPathComponent()
        let service = f.removal(failingPath: logs.path)
        let record = try await service.remove(report: f.scan(app), selectedIDs: [app.id, cache.path, logs.path], isRunning: { _ in false })
        expectFalse(record.succeeded)
        expectEqual(record.entries.map(\.status), [.trashed, .failed, .skipped])
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
        expectTrue(FileManager.default.fileExists(atPath: logs.path))
        expectFalse(FileManager.default.fileExists(atPath: cache.path))
        let saved = try await HistoryStore(url: f.historyURL).load()
        expectEqual(saved.first?.entries.map(\.status), record.entries.map(\.status))
    }

    func testCorruptJournalPreventsAnyMove() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        try f.makeParent(f.historyURL)
        try Data("invalid JSON".utf8).write(to: f.historyURL)
        do {
            _ = try await f.removal().remove(report: f.scan(app), selectedIDs: [app.id], isRunning: { _ in false })
            fail("Expected journal failure")
        } catch SweepError.historyUnavailable { }
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
        expectEqual(try String(contentsOf: f.historyURL, encoding: .utf8), "invalid JSON")
    }

    func testSymlinkJournalIsRejected() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        let target = try f.file("Important/history.json", contents: "[]")
        try f.makeParent(f.historyURL)
        try FileManager.default.createSymbolicLink(at: f.historyURL, withDestinationURL: target)
        do {
            _ = try await f.removal().remove(report: f.scan(app), selectedIDs: [app.id], isRunning: { _ in false })
            fail("Expected symlink journal rejection")
        } catch SweepError.historyUnavailable { }
        expectEqual(try String(contentsOf: target, encoding: .utf8), "[]")
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
    }

    func testUnknownSelectionCannotInjectAPath() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        do {
            _ = try await f.removal().remove(report: f.scan(app), selectedIDs: [f.home.path], isRunning: { _ in false })
            fail("Expected unknown selection rejection")
        } catch SweepError.selectionChanged { }
    }

    func testEmptySelectionDoesNotCreateJournal() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app()
        do {
            _ = try await f.removal().remove(report: f.scan(app), selectedIDs: [], isRunning: { _ in false })
            fail("Expected empty selection rejection")
        } catch SweepError.emptySelection { }
        expectFalse(FileManager.default.fileExists(atPath: f.historyURL.path))
    }

    func testBlockedAppCannotBeSelectedThroughTheService() async throws {
        let f = try Fixture(); defer { f.clean() }
        let app = try f.app(identifier: "com.apple.Test")
        do {
            _ = try await f.removal().remove(report: f.scan(app), selectedIDs: [app.id], isRunning: { _ in false })
            fail("Expected protected application rejection")
        } catch SweepError.blockedSelection { }
        expectTrue(FileManager.default.fileExists(atPath: app.url.path))
    }
}

private struct Fixture: Sendable {
    let root: URL
    let home: URL
    let apps: URL
    let context: ScanContext
    var scanner: AppScanner { AppScanner(context: context) }
    var historyURL: URL { root.appendingPathComponent("journal/history.json") }

    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("AppSweepTests-" + UUID().uuidString)
        home = root.appendingPathComponent("home")
        apps = root.appendingPathComponent("Applications")
        context = ScanContext(home: home, applicationRoots: [apps], serviceRoots: [root.appendingPathComponent("LaunchAgents")])
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    }

    func app(_ name: String = "Notebook", identifier: String = "org.example.Notebook") throws -> InstalledApp {
        let url = apps.appendingPathComponent(name + ".app")
        let info = url.appendingPathComponent("Contents/Info.plist")
        try makeParent(info)
        try writePlist(["CFBundleIdentifier": identifier, "CFBundleName": name,
                        "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"], at: info)
        if name.contains(".app/") {
            return InstalledApp(url: url, name: name, bundleIdentifier: identifier, version: "1.0",
                                identity: try requireValue(FileIdentity.read(url)))
        }
        return try scanner.inspect(url)
    }

    func file(_ path: String, contents: String = "fixture data") throws -> URL {
        let url = home.appendingPathComponent("Library/" + path)
        try makeParent(url)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func makeParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func writePlist(_ dictionary: [String: Any], at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: url)
    }

    func scan(_ app: InstalledApp) throws -> ScanReport { try scanner.scan(app, catalog: scanner.catalog()) }

    func removal(failingPath: String? = nil) -> RemovalService {
        RemovalService(context: context, history: HistoryStore(url: historyURL),
                       trash: FixtureTrash(root: root.appendingPathComponent("Trash"), failingPath: failingPath))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct FixtureTrash: TrashMoving {
    let root: URL
    let failingPath: String?
    func moveToTrash(_ url: URL) throws -> URL? {
        if url.path == failingPath { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
