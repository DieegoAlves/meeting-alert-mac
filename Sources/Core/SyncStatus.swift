// OWNER: Core. Shared infrastructure (like CalendarCatalog, F-053): Sync WRITES the outcome of
// each sync pass; Prefs and MenuBar READ it (F-057). This is the single source of truth for
// "when did we last sync, how many events, and what exactly went wrong" — so a silent failure
// (e.g. the Google Calendar API disabled in the project) is never invisible again.
//
// Not part of the frozen EventStore contract — a new, additive shared surface.
import Foundation
import Combine

/// Snapshot of the last sync outcome. Persisted to UserDefaults so the Preferences window shows
/// it even across relaunches, and so it can be inspected out-of-process for diagnostics.
public struct SyncStatusSnapshot: Codable, Sendable, Equatable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var calendarCount: Int
    public var eventCount: Int
    /// Human-readable message for the LAST pass if it failed; nil when the last pass succeeded.
    public var lastError: String?
    /// Set only when the failure is "Google Calendar API disabled in this project" — the direct
    /// activation URL Google returns in its 403 body, so the UI can offer a one-click fix.
    public var enableAPIURL: String?

    public init(
        lastAttempt: Date? = nil,
        lastSuccess: Date? = nil,
        calendarCount: Int = 0,
        eventCount: Int = 0,
        lastError: String? = nil,
        enableAPIURL: String? = nil
    ) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.calendarCount = calendarCount
        self.eventCount = eventCount
        self.lastError = lastError
        self.enableAPIURL = enableAPIURL
    }
}

@MainActor
public final class SyncStatusCenter: ObservableObject {
    public static let shared = SyncStatusCenter()

    private static let defaultsKey = "MeetingAlertSyncStatus"

    @Published public private(set) var snapshot: SyncStatusSnapshot

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SyncStatusSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = SyncStatusSnapshot()
        }
    }

    /// A sync pass just started.
    public func recordAttempt() {
        var s = snapshot
        s.lastAttempt = Date()
        commit(s)
    }

    /// A sync pass completed successfully — clears any prior error.
    public func recordSuccess(calendarCount: Int, eventCount: Int) {
        var s = snapshot
        let now = Date()
        s.lastAttempt = now
        s.lastSuccess = now
        s.calendarCount = calendarCount
        s.eventCount = eventCount
        s.lastError = nil
        s.enableAPIURL = nil
        commit(s)
    }

    /// A sync pass failed — keep the last-success info, record the exact reason.
    public func recordFailure(_ message: String, enableAPIURL: String? = nil) {
        var s = snapshot
        s.lastAttempt = Date()
        s.lastError = message
        s.enableAPIURL = enableAPIURL
        commit(s)
    }

    private func commit(_ s: SyncStatusSnapshot) {
        guard s != snapshot else { return }
        snapshot = s
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
