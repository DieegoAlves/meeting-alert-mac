// OWNER: App module. Demo/fixture mode — injects fake events so the app can be exercised
// (menu bar sections + T-1 overlay) WITHOUT Google OAuth credentials.
//
// Demo is OFF by default. It is an EXPLICIT opt-in: launch with MEETINGALERT_DEMO=1 (any
// non-empty value). It is AUTOMATICALLY force-disabled the moment a Google OAuth client ID
// is configured — a saved client ID means the user intends REAL mode, so the env flag is
// ignored and real Google sync takes over. (Root fix for: "pasted client ID but still sees
// demo events" — F-055.)
//
// Every demo event is tagged with the reserved `demoCalendarId` origin so real mode can
// purge them from the cache deterministically without touching real events.
//
// This is a developer/testing affordance only — it touches no persisted real data path
// beyond the in-memory EventStore for the current run.
import Foundation
import Core
import Auth   // GoogleAuth.clientIDDefaultsKey — the single source of truth for the client-ID key

enum DemoFixtures {
    /// Reserved calendar id that marks an event as demo-origin. Real Google calendar ids are
    /// e-mail-like/hex account ids and never collide with this, so it is a safe purge tag.
    static let demoCalendarId = "demo@meeting-alert.local"

    /// True only when demo mode should run: MEETINGALERT_DEMO is set non-empty AND no OAuth
    /// client ID is configured. A configured client ID always wins → real mode.
    static var isEnabled: Bool {
        if hasClientID { return false }   // client ID present → real mode, demo force-off
        guard let v = ProcessInfo.processInfo.environment["MEETINGALERT_DEMO"] else { return false }
        return !v.isEmpty
    }

    /// True when SOME OAuth client is configured — embedded at build time (F-065) OR pasted by the
    /// user. A distributed build ships with embedded credentials, so it runs REAL mode by default.
    static var hasClientID: Bool { OAuthClientConfig.isConfigured }

    /// Demo-origin test: an event that was seeded by this fixture set (tagged via `demoCalendarId`).
    static func isDemoEvent(_ event: CalendarEvent) -> Bool {
        event.calendarId == demoCalendarId
    }

    /// A Google Meet join link so the "Entrar" buttons and the overlay join action work.
    private static func meetJoin(_ code: String) -> MeetingJoin {
        MeetingJoin(
            provider: .meet,
            url: URL(string: "https://meet.google.com/\(code)")!,
            deepLinkURL: nil
        )
    }

    /// Four events covering every menu-bar surface + the T-1 overlay:
    ///  • ~90 s out  → "Próximas hoje" AND fires the T-1 overlay ~30 s after launch
    ///  • ongoing    → "Em Reunião" (late-join / "Já estou na call")
    ///  • +3 h       → "Próximas hoje" (later today)
    ///  • ended      → "Já passaram hoje" (history)
    static func events(now: Date = Date()) -> [CalendarEvent] {
        let cal = demoCalendarId
        return [
            CalendarEvent(
                id: "demo-overlay",
                calendarId: cal,
                title: "Standup (demo — overlay em ~30s)",
                start: now.addingTimeInterval(90),
                end: now.addingTimeInterval(90 + 1800),
                attendees: [],
                location: nil,
                description: nil,
                isAllDay: false,
                join: meetJoin("demo-standup")
            ),
            CalendarEvent(
                id: "demo-ongoing",
                calendarId: cal,
                title: "1:1 em andamento (demo)",
                start: now.addingTimeInterval(-600),
                end: now.addingTimeInterval(1200),
                attendees: [],
                location: nil,
                description: nil,
                isAllDay: false,
                join: meetJoin("demo-1on1")
            ),
            CalendarEvent(
                id: "demo-later",
                calendarId: cal,
                title: "Design Review (demo — mais tarde hoje)",
                start: now.addingTimeInterval(3 * 3600),
                end: now.addingTimeInterval(3 * 3600 + 1800),
                attendees: [],
                location: nil,
                description: nil,
                isAllDay: false,
                join: meetJoin("demo-review")
            ),
            CalendarEvent(
                id: "demo-past",
                calendarId: cal,
                title: "Sync da manhã (demo — já passou)",
                start: now.addingTimeInterval(-2 * 3600),
                end: now.addingTimeInterval(-90 * 60),
                attendees: [],
                location: nil,
                description: nil,
                isAllDay: false,
                join: meetJoin("demo-morning")
            ),
        ]
    }
}
