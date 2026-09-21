// OWNER: Core. Shared infrastructure (like EventStore): Sync WRITES the discovered calendar
// list, Prefs READS it to render the calendar picker (F-053). Not a per-module stub.
import Foundation
import Combine

/// One calendar discovered via Google `calendarList.list` (id, summary, primary flag, color).
public struct CalendarInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let summary: String
    public let isPrimary: Bool
    public let colorHex: String?   // Google `backgroundColor`, e.g. "#9fe1e7"

    public init(id: String, summary: String, isPrimary: Bool, colorHex: String?) {
        self.id = id
        self.summary = summary
        self.isPrimary = isPrimary
        self.colorHex = colorHex
    }
}

/// The set of calendars available on the signed-in account, published for the Prefs picker.
/// Sync refreshes it every poll; Prefs observes it. Empty until the first successful sync.
@MainActor
public final class CalendarCatalog: ObservableObject {
    public static let shared = CalendarCatalog()

    @Published public private(set) var calendars: [CalendarInfo] = []

    public init() {}

    /// Replace the catalog. Primary calendar (if any) is sorted first, then by name; the
    /// no-op guard avoids a spurious @Published churn when the list is unchanged.
    public func update(_ list: [CalendarInfo]) {
        let sorted = list.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }   // primary first
            return a.summary.localizedCaseInsensitiveCompare(b.summary) == .orderedAscending
        }
        guard sorted != calendars else { return }
        calendars = sorted
    }
}
