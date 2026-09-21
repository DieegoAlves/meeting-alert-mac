// OWNER: Core (frozen contract — do NOT edit after scaffold).
// Scheduler-owned protocols; AlertUI/MenuBar consume.
import Foundation

/// notify = T-5 UserNotification, overlay = T-1 NSPanel.
public enum AlertStage: String, Codable, Sendable {
    case notify, overlay
}

public enum SnoozeInterval: Int, CaseIterable, Sendable {
    case one = 1, three = 3, five = 5
}

/// Overlapping meetings collapse into ONE overlay.
public struct AlertGroup: Identifiable, Sendable {
    public let id: String
    public let events: [CalendarEvent]   // >= 1; multiple when time-overlapping
    public let stage: AlertStage
    public let fireDate: Date

    public init(id: String, events: [CalendarEvent], stage: AlertStage, fireDate: Date) {
        self.id = id
        self.events = events
        self.stage = stage
        self.fireDate = fireDate
    }
}

public protocol AlertScheduling: AnyObject {
    func start()                                        // arm on launch
    func rearmForNextAlert()                            // recompute after sync/wake/prefs change
    func nextAlertInstant() -> (date: Date, stage: AlertStage, group: AlertGroup)?
    func snooze(_ group: AlertGroup, by interval: SnoozeInterval)
    func dismiss(_ group: AlertGroup)                   // "Later" / Esc
    func markAlreadyInCall(_ event: CalendarEvent)      // per-event suppression for remaining stages
    func join(_ event: CalendarEvent)                   // opens join + suppresses that event
}

public protocol AlertPresenting: AnyObject {           // AlertUI implements; Scheduler calls
    func present(_ group: AlertGroup)                   // routes to notification (T-5) or overlay (T-1)
    /// F-052: deliver a silent, passive notification instead of the full-screen overlay —
    /// used when a macOS Focus/DND is active and the user has NOT opted to ignore Focus.
    func presentSilentNotification(_ group: AlertGroup)
    func dismissActiveOverlay()
}
