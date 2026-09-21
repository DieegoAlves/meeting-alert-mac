// OWNER: Scheduler module (Sources/Scheduler). Depends on Core only.
//
// Per-event / per-stage bookkeeping the planner consults when deciding what to fire next:
//  - which (event, stage) alerts already fired (so a rearm cannot re-fire the same instant),
//  - which events are fully suppressed ("já estou na call" / joined),
//  - snooze overrides that re-arm a specific (event, stage) at a future instant.
// Pure value type — no timers, no side effects.
import Foundation
import Core

struct SnoozeState {
    struct Key: Hashable {
        let eventID: String
        let stage: AlertStage
    }

    /// (event, stage) pairs already delivered — dropped from planning unless a snooze override revives them.
    private(set) var fired: Set<Key> = []
    /// Events with ALL remaining stages suppressed (markAlreadyInCall / join).
    private(set) var suppressedEvents: Set<String> = []
    /// (event, stage) → rescheduled fire instant (snooze). Authoritative over the default lead time.
    private(set) var overrides: [Key: Date] = [:]

    func isSuppressed(_ eventID: String) -> Bool { suppressedEvents.contains(eventID) }

    /// A candidate is pending when it has NOT fired, or a snooze override has revived it.
    func isPending(_ key: Key) -> Bool { overrides[key] != nil || !fired.contains(key) }

    func override(for key: Key) -> Date? { overrides[key] }

    mutating func markFired(_ key: Key) {
        fired.insert(key)
        overrides[key] = nil            // a fired alert consumes its snooze override
    }

    mutating func suppress(_ eventID: String) {
        suppressedEvents.insert(eventID)
        overrides = overrides.filter { $0.key.eventID != eventID }
    }

    mutating func snooze(eventID: String, stage: AlertStage, until date: Date) {
        let key = Key(eventID: eventID, stage: stage)
        overrides[key] = date
        fired.remove(key)               // revive it so it fires again at `date`
    }

    /// Forget events no longer in the store window so state cannot grow unbounded across days.
    mutating func prune(keepingEventIDs ids: Set<String>) {
        fired = fired.filter { ids.contains($0.eventID) }
        suppressedEvents = suppressedEvents.filter { ids.contains($0) }
        overrides = overrides.filter { ids.contains($0.key.eventID) }
    }
}
