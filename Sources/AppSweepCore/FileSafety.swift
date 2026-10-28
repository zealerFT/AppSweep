import Darwin
import Foundation

public struct FileIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt16
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public var isDirectory: Bool { fileType == UInt16(S_IFDIR) }
    public var isSymbolicLink: Bool { fileType == UInt16(S_IFLNK) }

    public static func read(_ url: URL) throws -> FileIdentity? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return FileIdentity(device: UInt64(UInt32(bitPattern: information.st_dev)),
                            inode: UInt64(information.st_ino),
                            fileType: UInt16(information.st_mode & S_IFMT),
                            birthSeconds: Int64(information.st_birthtimespec.tv_sec),
                            birthNanoseconds: Int64(information.st_birthtimespec.tv_nsec))
    }
}

public struct ScanContext: Sendable {
    public let home: URL
    public let applicationRoots: [URL]
    public let serviceRoots: [URL]
    public let ownBundleIdentifier: String

    public init(home: URL, applicationRoots: [URL], serviceRoots: [URL],
                ownBundleIdentifier: String = "com.example.AppSweep") {
        self.home = FileSafety.canonicalURL(home)
        self.applicationRoots = applicationRoots.map { $0.standardized }
        self.serviceRoots = serviceRoots.map { $0.standardized }
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    public static func live(ownBundleIdentifier: String) -> ScanContext {
        let home = FileSafety.canonicalURL(FileManager.default.homeDirectoryForCurrentUser)
        return ScanContext(
            home: home,
            applicationRoots: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            serviceRoots: [URL(fileURLWithPath: "/Library/LaunchAgents"),
                           URL(fileURLWithPath: "/Library/LaunchDaemons"),
                           home.appendingPathComponent("Library/LaunchAgents")],
            ownBundleIdentifier: ownBundleIdentifier
        )
    }

    public func protects(_ identifier: String) -> Bool {
        identifier.lowercased() == ownBundleIdentifier.lowercased() || identifier.lowercased().hasPrefix("com.apple.")
    }

    public func permitsApplicationPath(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app", FileSafety.hasNoSymlinkComponents(url) else { return false }
        return applicationRoots.contains { root in
            guard FileSafety.isDescendant(url, of: root) else { return false }
            let relative = url.path.dropFirst(root.path.count + 1).split(separator: "/")
            return relative.count <= 4 && !relative.dropLast().contains { $0.lowercased().hasSuffix(".app") }
        }
    }
}

enum FileSafety {
    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        url.standardized.path.hasPrefix(root.standardized.path + "/")
    }

    static func hasNoSymlinkComponents(_ url: URL) -> Bool {
        guard url.path == url.standardized.path else { return false }
        var cursor = url
        while cursor.path != "/" && !cursor.path.isEmpty {
            do {
                if try FileIdentity.read(cursor)?.isSymbolicLink == true { return false }
            } catch { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }

    // Foundation's standardizedFileURL rewrites /private/var back to /var.
    // Use realpath only for trusted roots; candidates retain their original
    // paths and are checked component-by-component without following links.
    static func canonicalURL(_ url: URL) -> URL {
        let normalized = url.standardized
        if let resolved = realpath(normalized.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        guard normalized.path != "/", !normalized.path.isEmpty else { return normalized }
        return canonicalURL(normalized.deletingLastPathComponent()).appendingPathComponent(normalized.lastPathComponent)
    }

    static func validBundleIdentifier(_ identifier: String) -> Bool {
        guard identifier.count <= 255, identifier.contains("."), !identifier.contains(".."),
              !identifier.hasPrefix("."), !identifier.hasSuffix(".") else { return false }
        return identifier.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0)
        }
    }

    static func plist(_ url: URL) throws -> [String: Any] {
        guard hasNoSymlinkComponents(url), let identity = try FileIdentity.read(url),
              !identity.isDirectory, !identity.isSymbolicLink else { throw SweepError.unsafePath }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 1_048_576 else {
            throw SweepError.invalidApplication
        }
        let data = try Data(contentsOf: url)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SweepError.invalidApplication
        }
        return value
    }

    static func application(_ url: URL, context: ScanContext) throws -> InstalledApp {
        guard context.permitsApplicationPath(url), let identity = try FileIdentity.read(url),
              identity.isDirectory else { throw SweepError.invalidApplication }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let infoIdentity = try FileIdentity.read(infoURL), !infoIdentity.isDirectory else {
            throw SweepError.invalidApplication
        }
        let info: [String: Any]
        do {
            info = try plist(infoURL)
        } catch SweepError.unsafePath {
            throw SweepError.invalidApplication
        }
        guard let identifier = info["CFBundleIdentifier"] as? String,
              validBundleIdentifier(identifier), info["CFBundlePackageType"] as? String == "APPL" else {
            throw SweepError.invalidApplication
        }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(url: url, name: name, bundleIdentifier: identifier,
                            version: info["CFBundleShortVersionString"] as? String ?? "",
                            identity: identity)
    }
}
