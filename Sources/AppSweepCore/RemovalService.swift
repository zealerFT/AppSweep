import AppKit
import Foundation

public protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL?
}

public struct SystemTrash: TrashMoving {
    private let direct: any TrashMoving
    private let applicationFallback: any TrashMoving

    public init(direct: any TrashMoving = WorkspaceTrash(),
                applicationFallback: any TrashMoving = FinderTrash()) {
        self.direct = direct
        self.applicationFallback = applicationFallback
    }

    public func moveToTrash(_ url: URL) async throws -> URL? {
        guard FileSafety.hasNoSymlinkComponents(url),
              let identity = try FileIdentity.read(url) else { throw SweepError.selectionChanged }
        let destination: URL?
        do {
            destination = try await direct.moveToTrash(url)
        } catch {
            // Recycle does not authenticate or delegate to Finder. Only retry
            // an unchanged application after an actual permission denial.
            guard RemovalFailure(error).kind == .permissionDenied,
                  url.pathExtension.lowercased() == "app", identity.isDirectory else { throw error }
            try Task.checkCancellation()
            guard FileSafety.hasNoSymlinkComponents(url),
                  try FileIdentity.read(url) == identity else { throw SweepError.selectionChanged }
            // Propagate Finder's error (including cancellation or Automation
            // denial), rather than masking it with the original 513.
            destination = try await applicationFallback.moveToTrash(url)
        }
        // A successful callback alone is not proof of removal. Do not let
        // later data removal run until the original is gone and the returned
        // item is the same file, on the same volume, at a non-symlink path.
        guard let destination, FileSafety.hasNoSymlinkComponents(destination),
              try FileIdentity.read(url) == nil,
              try FileIdentity.read(destination) == identity else { throw SweepError.selectionChanged }
        return destination
    }
}

public struct WorkspaceTrash: TrashMoving {
    public init() {}
    @MainActor public func moveToTrash(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { destinations, error in
                if let destination = destinations[url] {
                    continuation.resume(returning: destination)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                }
            }
        }
    }
}

public actor RemovalService {
    private let scanner: AppScanner
    private let history: HistoryStore
    private let trash: any TrashMoving
    private var busy = false

    public init(context: ScanContext, history: HistoryStore, trash: any TrashMoving = SystemTrash()) {
        self.scanner = AppScanner(context: context)
        self.history = history
        self.trash = trash
    }

    public func remove(report: ScanReport, selectedIDs: Set<String>,
                       isRunning: @Sendable (InstalledApp) async -> Bool) async throws -> OperationRecord {
        guard !busy else { throw SweepError.busy }
        busy = true
        defer { busy = false }
        guard !selectedIDs.isEmpty else { throw SweepError.emptySelection }
        let selected = report.candidates.filter { selectedIDs.contains($0.id) }.sorted {
            if ($0.kind == .application) != ($1.kind == .application) { return $0.kind == .application }
            return $0.id < $1.id
        }
        guard selected.count == selectedIDs.count else { throw SweepError.selectionChanged }
        guard selected.allSatisfy(\.canSelect) else { throw SweepError.blockedSelection }
        if await isRunning(report.app) { throw SweepError.runningApplication }
        try Task.checkCancellation()

        let fresh = try scanner.scan(report.app, catalog: scanner.catalog(), measureSizes: false)
        for item in selected {
            guard let current = fresh.candidates.first(where: { $0.id == item.id }),
                  current.identity == item.identity, current.kind == item.kind,
                  current.canSelect else { throw SweepError.selectionChanged }
        }
        var record = OperationRecord(id: UUID(), date: Date(), appName: report.app.name,
                                     bundleIdentifier: report.app.bundleIdentifier,
                                     entries: selected.map {
            OperationEntry(originalPath: $0.url.path, status: .pending)
        }, finished: false)
        do { try await history.save(record) }
        catch { throw SweepError.historyUnavailable(error.localizedDescription) }

        // Resolve app removal before touching user data. If macOS refuses the
        // app or the user cancels, leave all selected data in place.
        var trashedApplication: URL?
        for index in selected.indices {
            let item = selected[index]
            do {
                try Task.checkCancellation()
                if await isRunning(report.app) { throw SweepError.runningApplication }
                guard FileSafety.hasNoSymlinkComponents(item.url),
                      try FileIdentity.read(item.url) == item.identity else {
                    throw SweepError.selectionChanged
                }
                if let trashedApplication {
                    // A newly installed app at the old path must not lose its
                    // data. Also retain the original identity check in Trash.
                    guard try FileIdentity.read(report.app.url) == nil,
                          FileSafety.hasNoSymlinkComponents(trashedApplication),
                          try FileIdentity.read(trashedApplication) == report.app.identity else {
                        throw SweepError.selectionChanged
                    }
                } else {
                    guard try FileIdentity.read(report.app.url) == report.app.identity else {
                        throw SweepError.selectionChanged
                    }
                }
                let result = try await trash.moveToTrash(item.url)
                record.entries[index].trashPath = result?.path
                record.entries[index].status = .trashed
                if item.kind == .application { trashedApplication = result }
            } catch {
                record.entries[index].status = .failed
                record.entries[index].error = error.localizedDescription
                record.entries[index].failure = RemovalFailure(error)
                for remaining in selected.indices where remaining > index {
                    record.entries[remaining].status = .skipped
                }
            }
            do { try await history.save(record) }
            catch {
                record.journalError = error.localizedDescription
                for remaining in selected.indices where remaining > index {
                    record.entries[remaining].status = .skipped
                }
                break
            }
            if record.entries[index].status == .failed { break }
        }
        record.finished = true
        do { try await history.save(record) }
        catch { record.journalError = error.localizedDescription }
        return record
    }
}
