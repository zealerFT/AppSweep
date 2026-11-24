import Foundation

/// Informational catalog values, never used to authorize removal.
public struct ApplicationMetadata: Hashable, Sendable {
    public let size: SizeEstimate?
    public let lastUsed: Date?

    public init(size: SizeEstimate? = nil, lastUsed: Date? = nil) {
        self.size = size
        self.lastUsed = lastUsed
    }
}

public enum ApplicationSortOrder: String, CaseIterable, Sendable {
    case name, identifier, largest, smallest, leastRecentlyUsed, mostRecentlyUsed

    public func sorted(_ apps: [InstalledApp], metadata: [String: ApplicationMetadata]) -> [InstalledApp] {
        apps.sorted { left, right in
            let a = metadata[left.id], b = metadata[right.id]
            let comparison: Bool?
            switch self {
            case .largest, .smallest:
                comparison = compare(a?.size?.bytes, b?.size?.bytes, descending: self == .largest)
            case .leastRecentlyUsed, .mostRecentlyUsed:
                comparison = compare(a?.lastUsed, b?.lastUsed, descending: self == .mostRecentlyUsed)
            case .identifier:
                let order = left.bundleIdentifier.localizedStandardCompare(right.bundleIdentifier)
                comparison = order == .orderedSame ? nil : order == .orderedAscending
            case .name:
                comparison = nil
            }
            if let comparison { return comparison }
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    /// Unknown values stay at the end in either direction, including while loading.
    private func compare<Value: Comparable>(_ left: Value?, _ right: Value?, descending: Bool) -> Bool? {
        switch (left, right) {
        case let (left?, right?):
            return left == right ? nil : (descending ? left > right : left < right)
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
}
