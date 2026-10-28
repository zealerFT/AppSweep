import Foundation

public struct AppScanner: Sendable {
    public let context: ScanContext
    public init(context: ScanContext) { self.context = context }

    public func inspect(_ url: URL) throws -> InstalledApp {
        try FileSafety.application(url, context: context)
    }

    public func catalog() throws -> CatalogReport {
        var applications: [InstalledApp] = []
        var issues: [ScanIssue] = []
        func visit(_ directory: URL, depth: Int) throws {
            try Task.checkCancellation()
            for child in entries(directory, issues: &issues) {
                try Task.checkCancellation()
                do {
                    guard let identity = try FileIdentity.read(child), !identity.isSymbolicLink,
                          identity.isDirectory else { continue }
                    if child.pathExtension.lowercased() == "app" {
                        do {
                            applications.append(try FileSafety.application(child, context: context))
                        } catch SweepError.invalidApplication {
                            issues.append(ScanIssue(kind: .invalidApplication, path: child.path,
                                                    detail: SweepError.invalidApplication.errorDescription ?? ""))
                        }
                    } else if depth < 3 {
                        try visit(child, depth: depth + 1)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    issues.append(ScanIssue(kind: .inaccessible, path: child.path, detail: error.localizedDescription))
                }
            }
        }
        for root in context.applicationRoots { try visit(root, depth: 0) }
        return CatalogReport(applications: applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, issues: issues)
    }

    public func scan(_ app: InstalledApp, catalog: CatalogReport,
                     measureSizes: Bool = true) throws -> ScanReport {
        let current = try FileSafety.application(app.url, context: context)
        guard current.identity == app.identity, current.bundleIdentifier == app.bundleIdentifier else {
            throw SweepError.selectionChanged
        }
        var issues = catalog.issues
        let duplicates = catalog.applications.filter { $0.bundleIdentifier.lowercased() == app.bundleIdentifier.lowercased() }
        let shared = duplicates.count > 1
        if shared {
            issues.append(ScanIssue(kind: .sharedIdentifier, path: app.bundleIdentifier,
                                    detail: duplicates.map(\.url.path).joined(separator: "\n")))
        }
        let official = requiresOfficialUninstaller(app, issues: &issues)
        let appBlock: BlockReason? = context.protects(app.bundleIdentifier) ? .protectedApplication
            : (official ? .officialUninstaller : nil)
        var candidates: [RemovalCandidate] = []

        func append(_ url: URL, kind: CandidateKind) throws {
            try Task.checkCancellation()
            do {
                guard let identity = try FileIdentity.read(url) else { return }
                let unsafe = identity.isSymbolicLink || !FileSafety.hasNoSymlinkComponents(url)
                let blocked = unsafe ? BlockReason.unsafePath : appBlock
                    ?? (shared && kind != .application ? .sharedIdentifier : nil)
                let size = measureSizes && !unsafe ? try estimateSize(url) : SizeEstimate()
                if !size.complete { issues.append(ScanIssue(kind: .incompleteSize, path: url.path)) }
                if unsafe { issues.append(ScanIssue(kind: .unsafePath, path: url.path)) }
                candidates.append(RemovalCandidate(url: url, kind: kind, identity: identity,
                                                   size: size, blockReason: blocked))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ScanIssue(kind: .inaccessible, path: url.path, detail: error.localizedDescription))
            }
        }

        try append(app.url, kind: .application)
        for rule in Self.libraryRules(identifier: app.bundleIdentifier) {
            let root = context.home.appendingPathComponent("Library").appendingPathComponent(rule.directory)
            let children = entries(root, issues: &issues)
            for child in children where rule.names.contains(child.lastPathComponent) {
                try append(child, kind: rule.kind)
            }
        }
        let byHost = context.home.appendingPathComponent("Library/Preferences/ByHost")
        for child in entries(byHost, issues: &issues) {
            let name = child.lastPathComponent
            let prefix = app.bundleIdentifier + "."
            guard name.hasPrefix(prefix), name.hasSuffix(".plist") else { continue }
            let uuid = String(name.dropFirst(prefix.count).dropLast(".plist".count))
            if UUID(uuidString: uuid) != nil { try append(child, kind: .preferences) }
        }
        return ScanReport(app: app, candidates: candidates,
                          issues: Array(Set(issues)).sorted { $0.id < $1.id }, scannedAt: Date())
    }

    private struct LibraryRule {
        let directory: String
        let names: Set<String>
        let kind: CandidateKind
    }

    private static func libraryRules(identifier: String) -> [LibraryRule] {
        [
            LibraryRule(directory: "Caches", names: [identifier], kind: .cache),
            LibraryRule(directory: "Logs", names: [identifier], kind: .logs),
            LibraryRule(directory: "Preferences", names: [identifier + ".plist"], kind: .preferences),
            LibraryRule(directory: "Saved Application State", names: [identifier + ".savedState"], kind: .savedState),
            LibraryRule(directory: "Application Support", names: [identifier], kind: .applicationData),
            LibraryRule(directory: "Containers", names: [identifier], kind: .container),
            LibraryRule(directory: "HTTPStorages", names: [identifier, identifier + ".binarycookies"], kind: .webData),
            LibraryRule(directory: "WebKit", names: [identifier], kind: .webData)
        ]
    }

    private func entries(_ directory: URL, issues: inout [ScanIssue]) -> [URL] {
        do {
            guard let identity = try FileIdentity.read(directory) else { return [] }
            guard identity.isDirectory, !identity.isSymbolicLink,
                  FileSafety.hasNoSymlinkComponents(directory) else {
                issues.append(ScanIssue(kind: .unsafePath, path: directory.path))
                return []
            }
            return try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil,
                                                               options: [])
        } catch {
            issues.append(ScanIssue(kind: .inaccessible, path: directory.path, detail: error.localizedDescription))
            return []
        }
    }

    private func requiresOfficialUninstaller(_ app: InstalledApp, issues: inout [ScanIssue]) -> Bool {
        var found = false
        let embedded = ["SystemExtensions", "Extensions", "LaunchServices", "LoginItems", "LaunchAgents", "LaunchDaemons"]
        for name in embedded {
            let location = app.url.appendingPathComponent("Contents/Library/" + name)
            let countBefore = issues.count
            if !entries(location, issues: &issues).isEmpty || issues.count > countBefore {
                found = true
                issues.append(ScanIssue(kind: .officialUninstaller, path: location.path))
            }
        }
        if let info = try? FileSafety.plist(app.url.appendingPathComponent("Contents/Info.plist")),
           let helpers = info["SMPrivilegedExecutables"] as? [String: Any], !helpers.isEmpty {
            found = true
            issues.append(ScanIssue(kind: .officialUninstaller, path: app.url.path,
                                    detail: helpers.keys.sorted().joined(separator: ", ")))
        }
        for root in context.serviceRoots {
            for url in entries(root, issues: &issues) where url.pathExtension == "plist" {
                do {
                    let job = try FileSafety.plist(url)
                    let label = job["Label"] as? String ?? ""
                    let executable = (job["Program"] as? String)
                        ?? (job["ProgramArguments"] as? [String])?.first ?? ""
                    let belongs = label.lowercased() == app.bundleIdentifier.lowercased()
                        || label.lowercased().hasPrefix(app.bundleIdentifier.lowercased() + ".")
                        || executable.hasPrefix(app.url.path + "/")
                    if belongs {
                        found = true
                        issues.append(ScanIssue(kind: .officialUninstaller, path: url.path, detail: label))
                    }
                } catch {
                    issues.append(ScanIssue(kind: .inaccessible, path: url.path, detail: error.localizedDescription))
                }
            }
        }
        return found
    }

    private func estimateSize(_ url: URL) throws -> SizeEstimate {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let identity = try FileIdentity.read(url) else { throw SweepError.selectionChanged }
        if !identity.isDirectory {
            let values = try url.resourceValues(forKeys: keys)
            return SizeEstimate(bytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
        }
        var complete = true
        var total: Int64 = 0
        var count = 0
        let deadline = Date().addingTimeInterval(6)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [], errorHandler: { _, _ in
            complete = false
            return true
        }) else { return SizeEstimate(complete: false) }
        for case let child as URL in enumerator {
            count += 1
            if count % 128 == 0 {
                try Task.checkCancellation()
                if count >= 80_000 || Date() > deadline { complete = false; break }
            }
            do {
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true {
                    total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
            } catch { complete = false; enumerator.skipDescendants() }
        }
        return SizeEstimate(bytes: total, complete: complete)
    }
}
