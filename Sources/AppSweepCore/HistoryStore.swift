import Foundation

public actor HistoryStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [OperationRecord] {
        guard try FileIdentity.read(url) != nil else { return [] }
        guard FileSafety.hasNoSymlinkComponents(url) else { throw SweepError.unsafePath }
        return try JSONDecoder().decode([OperationRecord].self, from: Data(contentsOf: url))
            .sorted { $0.date > $1.date }
    }

    public func save(_ record: OperationRecord) throws {
        var records = try load()
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        let parent = url.deletingLastPathComponent()
        guard FileSafety.hasNoSymlinkComponents(parent), FileSafety.hasNoSymlinkComponents(url) else {
            throw SweepError.unsafePath
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
