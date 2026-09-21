// OWNER: Core (frozen contract — do NOT edit after scaffold).
// Application Support locations + shared JSON coders used across modules.
import Foundation

public enum AppPaths {
    /// Folder name under ~/Library/Application Support.
    public static let bundleFolderName = "MeetingAlert"

    public static var appSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(bundleFolderName, isDirectory: true)
    }

    /// Cached events JSON (EventStore.load/persist).
    public static var eventStoreURL: URL {
        appSupportDirectory.appendingPathComponent("events.json")
    }

    /// Persisted user preferences JSON (PreferencesStore).
    public static var preferencesURL: URL {
        appSupportDirectory.appendingPathComponent("preferences.json")
    }

    /// Ensure the support directory exists before a write.
    public static func ensureAppSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
    }
}

public extension JSONEncoder {
    /// Shared encoder: ISO-8601 dates, stable key order.
    static var meetingAlert: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    /// Shared decoder matching `JSONEncoder.meetingAlert`.
    static var meetingAlert: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
