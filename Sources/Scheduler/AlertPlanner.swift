// OWNER: Scheduler module (Sources/Scheduler). Depends on Core only.
//
// Pure next-instant computation: turns the current EventStore snapshot + Preferences + SnoozeState
// into the AlertGroups to arm/fire, collapsing coincident-instant meetings of the SAME stage into
// ONE overlay (overlapping meetings). No timers, no side effects — AlertScheduler owns arming.
import Foundation
import Core

struct AlertPlanner {
    /// A candidate whose fire instant is older than this (seconds) is treated as missed and dropped,
    /// so a stale meeting cannot trigger a burst of alerts at launch or after a long sleep.
    static let staleGrace: TimeInterval = 5
    /// Widen the "due now" bucket to absorb DispatchSourceTimer leeway + coincident instants.
    static let fireWindow: TimeInterval = 2

    private let stages: [AlertStage] = [.notify, .overlay]

    struct Candidate {
        let event: CalendarEvent
        let stage: AlertStage
        let fireDate: Date
    }

    /// All still-relevant (event, stage, fireDate) alerts, honoring calendar filter, self-declines,
    /// suppression, fired/snooze state and the stale-grace floor.
    func candidates(events: [CalendarEvent], preferences: Preferences, state: SnoozeState, now: Date) -> [Candidate] {
        var result: [Candidate] = []
        for event in events {
            if state.isSuppressed(event.id) { continue }
            if !isIncluded(event, preferences) { continue }
            if isDeclined(event) { continue }
            if event.isAllDay { continue }
            for stage in stages {
                let key = SnoozeState.Key(eventID: event.id, stage: stage)
                guard state.isPending(key) else { continue }
                let leadMin = preferences.leadMinutes[stage] ?? Self.defaultLead(stage)
                let fireDate = state.override(for: key) ?? event.start.addingTimeInterval(-TimeInterval(leadMin * 60))
                if fireDate < now - Self.staleGrace { continue }   // missed — drop
                result.append(Candidate(event: event, stage: stage, fireDate: fireDate))
            }
        }
        return result
    }

    /// Coincident-instant, same-stage candidates collapse into one AlertGroup (overlapping meetings),
    /// returned earliest-first.
    func groups(events: [CalendarEvent], preferences: Preferences, state: SnoozeState, now: Date) -> [AlertGroup] {
        let cands = candidates(events: events, preferences: preferences, state: state, now: now)
        var buckets: [String: [Candidate]] = [:]
        for c in cands {
            // Bucket by stage + fireDate rounded to the second → coincident instants group together.
            let bucketKey = "\(c.stage.rawValue)@\(Int(c.fireDate.timeIntervalSinceReferenceDate.rounded()))"
            buckets[bucketKey, default: []].append(c)
        }
        return buckets.values.map { members in
            let sorted = members.sorted { $0.event.start < $1.event.start }
            let stage = sorted[0].stage
            let fireDate = sorted.map(\.fireDate).min() ?? sorted[0].fireDate
            let groupEvents = sorted.map(\.event)
            return AlertGroup(
                id: Self.groupID(stage: stage, events: groupEvents),
                events: groupEvents,
                stage: stage,
                fireDate: fireDate
            )
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    /// The single next group to arm the timer for (earliest fireDate), if any.
    func nextGroup(events: [CalendarEvent], preferences: Preferences, state: SnoozeState, now: Date) -> AlertGroup? {
        groups(events: events, preferences: preferences, state: state, now: now).first
    }

    /// Groups due at `now` (within fireWindow) — what actually fires when the timer trips.
    func dueGroups(events: [CalendarEvent], preferences: Preferences, state: SnoozeState, now: Date) -> [AlertGroup] {
        groups(events: events, preferences: preferences, state: state, now: now)
            .filter { $0.fireDate <= now + Self.fireWindow }
    }

    // MARK: - Helpers

    // F-053: a calendar is enabled unless its id is in the disabled set (empty == all enabled).
    private func isIncluded(_ event: CalendarEvent, _ prefs: Preferences) -> Bool {
        !prefs.disabledCalendarIDs.contains(event.calendarId)
    }

    private func isDeclined(_ event: CalendarEvent) -> Bool {
        event.attendees.first(where: { $0.isSelf })?.responseStatus == .declined
    }

    static func defaultLead(_ stage: AlertStage) -> Int {
        switch stage {
        case .notify: return 5
        case .overlay: return 1
        }
    }

    /// Deterministic id so a group handed to AlertUI round-trips back to snooze/dismiss unchanged.
    static func groupID(stage: AlertStage, events: [CalendarEvent]) -> String {
        stage.rawValue + "|" + events.map(\.id).sorted().joined(separator: ",")
    }
}
