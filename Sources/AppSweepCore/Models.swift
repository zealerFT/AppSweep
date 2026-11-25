import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let identity: FileIdentity

    public init(url: URL, name: String, bundleIdentifier: String, version: String,
                identity: FileIdentity) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.identity = identity
    }
}

public enum CandidateKind: String, Codable, CaseIterable, Sendable {
    case application, cache, logs, preferences, savedState, applicationData, container, webData

    public var selectedByDefault: Bool {
        self == .application || self == .cache || self == .logs
    }

    public var containsUserData: Bool { !selectedByDefault }
}

public enum BlockReason: String, Codable, Sendable {
    case protectedApplication, unsafePath, sharedIdentifier, officialUninstaller
}

public struct SizeEstimate: Hashable, Sendable {
    public let bytes: Int64
    public let complete: Bool
    public init(bytes: Int64 = 0, complete: Bool = true) {
        self.bytes = bytes
        self.complete = complete
    }
}

public struct RemovalCandidate: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let kind: CandidateKind
    public let identity: FileIdentity
    public let size: SizeEstimate
    public let blockReason: BlockReason?
    public var canSelect: Bool { blockReason == nil }
}

public enum ScanIssueKind: String, Codable, Sendable {
    case inaccessible, invalidApplication, incompleteSize, sharedIdentifier, officialUninstaller, unsafePath

    /// Whether the user can take an action that may change the next scan.
    /// Invalid application bundles are catalog notes: they are skipped safely,
    /// but Full Disk Access cannot repair their package structure.
    public var isActionable: Bool {
        self != .invalidApplication
    }
}

public struct ScanIssue: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue + ":" + path }
    public let kind: ScanIssueKind
    public let path: String
    public let detail: String

    public init(kind: ScanIssueKind, path: String, detail: String = "") {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

public struct CatalogReport: Sendable {
    public let applications: [InstalledApp]
    public let issues: [ScanIssue]
}

public struct ScanReport: Sendable {
    public let app: InstalledApp
    public let candidates: [RemovalCandidate]
    public let issues: [ScanIssue]
    public let scannedAt: Date
}

public enum EntryStatus: String, Codable, Sendable {
    case pending, trashed, failed, skipped
}

public struct OperationEntry: Identifiable, Codable, Sendable {
    public var id: String { originalPath }
    public let originalPath: String
    public var trashPath: String?
    public var status: EntryStatus
    public var error: String?
    public var failure: RemovalFailure?
}

public struct RemovalFailure: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case permissionDenied, cancelled, other }
    public let kind: Kind
    public let domain: String
    public let code: Int

    public init(_ error: Error) {
        let original = error as NSError
        domain = original.domain
        code = original.code
        var current = original
        var classified = Kind.other
        // Preserve a small, non-sensitive diagnostic instead of serializing
        // NSError.userInfo. Permission failures are often wrapped by Cocoa.
        for _ in 0..<8 {
            if (current.domain == NSCocoaErrorDomain && current.code == CocoaError.userCancelled.rawValue)
                || (current.domain == NSOSStatusErrorDomain && current.code == -128)
                || (current.domain == NSPOSIXErrorDomain && current.code == Int(ECANCELED)) {
                classified = .cancelled
                break
            }
            if (current.domain == NSCocoaErrorDomain && [CocoaError.fileWriteNoPermission.rawValue,
                                                       CocoaError.fileReadNoPermission.rawValue].contains(current.code))
                || (current.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(current.code))
                || (current.domain == NSOSStatusErrorDomain && [-54, -5000].contains(current.code)) {
                classified = .permissionDenied
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        kind = classified
    }
}

public struct OperationRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let appName: String
    public let bundleIdentifier: String
    public var entries: [OperationEntry]
    public var finished: Bool
    public var journalError: String?

    public var trashedCount: Int { entries.filter { $0.status == .trashed }.count }
    public var succeeded: Bool {
        finished && journalError == nil && entries.allSatisfy { $0.status == .trashed }
    }
}

public enum SweepError: LocalizedError, Sendable {
    case invalidApplication, unsafePath, selectionChanged, runningApplication
    case blockedSelection, emptySelection, busy, historyUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: "The application is missing or its bundle identity is invalid."
        case .unsafePath: "The path is outside the allowed scope or contains a symbolic link."
        case .selectionChanged: "Files or ownership changed after scanning. Scan again before removing."
        case .runningApplication: "The application is running. Quit it before removing any files."
        case .blockedSelection: "This selection is protected or requires the official uninstaller."
        case .emptySelection: "No files are selected."
        case .busy: "Another removal is in progress."
        case .historyUnavailable(let detail): "The operation journal could not be saved: \(detail)"
        }
    }
}
