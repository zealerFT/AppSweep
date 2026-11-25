import AppKit
import Carbon
import Foundation

/// Uses Finder's documented `delete` command, which moves an item to Trash.
/// No shell commands, permanent deletion, privilege changes or Trash emptying.
public struct FinderTrash: TrashMoving {
    public init() {}

    @MainActor public func moveToTrash(_ url: URL) async throws -> URL? {
        try Task.checkCancellation()
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileSafety.hasNoSymlinkComponents(url),
              let identity = try FileIdentity.read(url), identity.isDirectory else { throw SweepError.unsafePath }
        // Finder can offer immediate deletion on volumes without Trash.
        // Require an actual Trash directory on this volume before delegating.
        let trashDirectory = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                         appropriateFor: url, create: true).standardized
        guard FileSafety.hasNoSymlinkComponents(trashDirectory),
              let trashIdentity = try FileIdentity.read(trashDirectory), trashIdentity.isDirectory,
              trashIdentity.device == identity.device else { throw SweepError.unsafePath }

        // The path is a typed parameter, never interpolated into script source.
        // Finder owns any system authorization dialogs. It is not activated
        // and AppSweep neither supplies credentials nor dismisses dialogs.
        let source = """
        on trashApplication(applicationPath)
            set sourceItem to POSIX file applicationPath as alias
            with timeout of 600 seconds
                tell application id "com.apple.finder"
                    set movedItem to delete sourceItem
                    set movedAlias to movedItem as alias
                end tell
            end timeout
            return POSIX path of movedAlias
        end trashApplication
        """
        guard let script = NSAppleScript(source: source) else { throw CocoaError(.executableNotLoadable) }
        var details: NSDictionary?
        let reply = script.executeAppleEvent(Self.request(for: url), error: &details)
        if let details {
            let code = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -2700
            let message = details[NSAppleScript.errorMessage] as? String ?? "Finder could not move the application to Trash."
            throw NSError(domain: NSOSStatusErrorDomain, code: code,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let path = reply.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = URL(fileURLWithPath: path).standardized
        guard FileSafety.isDescendant(destination, of: trashDirectory) else { throw SweepError.unsafePath }
        return destination
    }

    @MainActor package static func request(for url: URL) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                                          eventID: AEEventID(kASSubroutineEvent),
                                          targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "trashApplication"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}
