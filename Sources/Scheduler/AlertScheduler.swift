// OWNER: Scheduler module. This whole folder (Sources/Scheduler) belongs to the Scheduler builder.
// Files: AlertScheduler.swift, AlertPlanner.swift, SnoozeState.swift, FocusMonitor.swift.
// Depends on Core + Prefs (reads Preferences via PreferencesStore).
//
// AlertScheduler is the AlertScheduling implementation: ONE rearmed DispatchSourceTimer, armed for
// the single next alert instant across ALL upcoming events (both stages: T-5 notify + T-1 overlay).
// AlertPlanner computes that instant (calendar filter, self-declines, suppression, snooze, overlap
// grouping); FocusMonitor gates firing on Focus/DND; SnoozeState carries fired/suppressed/snooze
// bookkeeping. Holds a weak AlertPresenting; reads EventStore + Preferences. Never polls.
import Foundation
import AppKit
import Core
import Prefs

@MainActor
public final class AlertScheduler: @MainActor AlertScheduling {
    private let store: EventStore
    private weak var presenter: AlertPresenting?
    private let preferencesStore: PreferencesStore

    private let planner = AlertPlanner()
    private let focus = FocusMonitor()
    private var state = SnoozeState()

    /// The single armed timer (nil == disarmed; the perf target is exactly one at idle, zero at rest).
    private var timer: DispatchSourceTimer?

    /// F-063: a "Adiar" on the TEST overlay re-fires a test overlay after the snooze interval via
    /// this timer (the real snooze path can't, since the synthetic event is never in the store).
    /// Non-nil only between a test snooze and its re-fire; cancelled on any other test action.
    private var testSnoozeTimer: DispatchSourceTimer?

    public init(store: EventStore, presenter: AlertPresenting, preferencesStore: PreferencesStore) {
        self.store = store
        self.presenter = presenter
        self.preferencesStore = preferencesStore
    }

    // MARK: - AlertScheduling

    public func start() { arm() }

    public func rearmForNextAlert() { arm() }

    public func nextAlertInstant() -> (date: Date, stage: AlertStage, group: AlertGroup)? {
        state.prune(keepingEventIDs: Set(store.events.map(\.id)))
        guard let group = planner.nextGroup(
            events: store.events,
            preferences: preferencesStore.preferences,
            state: state,
            now: Date()
        ) else { return nil }
        return (group.fireDate, group.stage, group)
    }

    public func snooze(_ group: AlertGroup, by interval: SnoozeInterval) {
        if Self.isTestGroup(group) { snoozeTest(by: interval); return }   // F-063
        let fireAt = Date().addingTimeInterval(TimeInterval(snoozeMinutes(for: interval) * 60))
        for event in group.events {
            state.snooze(eventID: event.id, stage: group.stage, until: fireAt)
        }
        presenter?.dismissActiveOverlay()
        arm()
    }

    public func dismiss(_ group: AlertGroup) {
        if Self.isTestGroup(group) { endTest(); return }   // F-063: Depois/Esc just closes the test
        // Drop THIS stage for the grouped events; the other stage (if still pending) may still fire.
        for event in group.events {
            state.markFired(SnoozeState.Key(eventID: event.id, stage: group.stage))
        }
        presenter?.dismissActiveOverlay()
        arm()
    }

    public func markAlreadyInCall(_ event: CalendarEvent) {
        if Self.isTestEvent(event) { endTest(); return }   // F-063: just closes the test
        state.suppress(event.id)                 // suppress ALL remaining stages for this event
        presenter?.dismissActiveOverlay()
        arm()
    }

    public func join(_ event: CalendarEvent) {
        if Self.isTestEvent(event) {             // F-063: open the sample link, then close the test
            if let join = event.join { NSWorkspace.shared.open(join.deepLinkURL ?? join.url) }
            endTest()
            return
        }
        if let join = event.join {
            NSWorkspace.shared.open(join.deepLinkURL ?? join.url)
        }
        state.suppress(event.id)                 // joining a call suppresses its remaining alerts
        presenter?.dismissActiveOverlay()
        arm()
    }

    // MARK: - F-063: Test alert (exercises the REAL fire path with a synthetic event)

    /// Reserved id marking the synthetic test event/group so the action handlers above route to the
    /// test branch and NEVER touch SnoozeState, the EventStore, or the history.
    private static let testEventID = "meeting-alert.test-alert"

    private static func isTestEvent(_ event: CalendarEvent) -> Bool { event.id == testEventID }
    private static func isTestGroup(_ group: AlertGroup) -> Bool { group.events.contains(where: isTestEvent) }

    /// Fire the FULL T-1 overlay exactly like a real alert: builds only a synthetic `CalendarEvent`
    /// and hands it to the SAME `presenter.present(_:)` path `handleFire()` uses — same multi-monitor
    /// panels, sound, countdown, keyboard shortcuts and action wiring. Touches no real state.
    public func fireTestAlert() {
        cancelTestSnooze()                       // a manual re-fire supersedes any pending snooze
        presenter?.present(Self.makeTestGroup())
    }

    /// The synthetic overlay group: title "Reunião de teste", time = now, a Meet sample link.
    /// F-064: it carries sample participants, a location and a description so the "Testar alerta"
    /// preview exercises the GROUP 2 content toggles (participants/location/description/link).
    private static func makeTestGroup() -> AlertGroup {
        let now = Date()
        let event = CalendarEvent(
            id: testEventID,
            calendarId: "meeting-alert.test",
            title: "Reunião de teste",
            start: now,                          // time = now → overlay shows "Começou 00:00"
            end: now.addingTimeInterval(30 * 60),
            attendees: [
                Attendee(email: "ana.souza@example.com",   displayName: "Ana Souza",   responseStatus: .accepted,    isSelf: false, isOrganizer: true),
                Attendee(email: "bruno.lima@example.com",  displayName: "Bruno Lima",  responseStatus: .accepted,    isSelf: false, isOrganizer: false),
                Attendee(email: "carla.dias@example.com",  displayName: "Carla Dias",  responseStatus: .tentative,   isSelf: false, isOrganizer: false),
                Attendee(email: "diego@disco-tec.com",     displayName: "Diego",       responseStatus: .accepted,    isSelf: true,  isOrganizer: false),
                Attendee(email: "erik.melo@example.com",   displayName: "Erik Melo",   responseStatus: .needsAction, isSelf: false, isOrganizer: false)
            ],
            location: "Sala Vídeo 2 · Google Meet",
            description: "Alinhamento de teste do overlay: exercita participantes, descrição, local e link para você validar cada opção da tela de aviso.",
            isAllDay: false,
            join: MeetingJoin(
                provider: .meet,
                url: URL(string: "https://meet.google.com/test")!,
                deepLinkURL: nil
            )
        )
        return AlertGroup(id: "test-\(now.timeIntervalSince1970)", events: [event], stage: .overlay, fireDate: now)
    }

    /// Close the test overlay and drop any pending test-snooze re-fire (no orphan window/timer).
    private func endTest() {
        cancelTestSnooze()
        presenter?.dismissActiveOverlay()
    }

    /// "Adiar 1/3/5" on the test overlay: close it now and re-fire a fresh TEST overlay after the
    /// snooze interval — faithful to the real snooze, but self-contained (the synthetic event is
    /// never in the store, so the real planner would never re-fire it).
    private func snoozeTest(by interval: SnoozeInterval) {
        cancelTestSnooze()
        presenter?.dismissActiveOverlay()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Double(snoozeMinutes(for: interval) * 60), leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.testSnoozeTimer = nil
                self?.fireTestAlert()
            }
        }
        t.resume()
        testSnoozeTimer = t
    }

    private func cancelTestSnooze() {
        testSnoozeTimer?.cancel()
        testSnoozeTimer = nil
    }

    /// F-064: the fixed `SnoozeInterval` cases are positional SLOT tokens (.one→0, .three→1,
    /// .five→2); the real minute value comes from the user's configured `overlayOptions.snoozeMinutes`.
    /// With the default [1,3,5] this is identical to the pre-F-064 behavior.
    private func snoozeMinutes(for interval: SnoozeInterval) -> Int {
        let slots = preferencesStore.preferences.overlayOptions.normalizedSnoozeMinutes
        switch interval {
        case .one:   return slots[0]
        case .three: return slots[1]
        case .five:  return slots[2]
        }
    }

    // MARK: - Timer arming

    /// Disarm the single timer — the composition root calls this on `willSleep` to avoid a spurious
    /// fire on wake (it re-arms via `rearmForNextAlert()` on `didWake`).
    public func disarm() {
        timer?.cancel()
        timer = nil
        cancelTestSnooze()   // F-063: never leave a pending test re-fire across a sleep
    }

    /// Recompute the next instant and (re)arm the single timer. Idempotent; cancels any prior timer.
    private func arm() {
        timer?.cancel()
        timer = nil

        state.prune(keepingEventIDs: Set(store.events.map(\.id)))

        let prefs = preferencesStore.preferences
        let now = Date()

        // Paused: fire nothing. Wake exactly at pauseUntil to re-plan, so alerts resume on time.
        if let pauseUntil = prefs.pauseUntil, pauseUntil > now {
            schedule(at: pauseUntil)
            return
        }

        guard let next = planner.nextGroup(events: store.events, preferences: prefs, state: state, now: now) else {
            return   // nothing upcoming — zero armed timers, zero idle CPU
        }
        schedule(at: next.fireDate)
    }

    private func schedule(at date: Date) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(0, date.timeIntervalSinceNow)
        t.schedule(deadline: .now() + interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleFire() }
        }
        t.resume()
        timer = t
    }

    private func handleFire() {
        timer = nil   // this timer is consumed; arm() at the end re-arms for the following instant

        let prefs = preferencesStore.preferences
        let now = Date()

        // Woke at pauseUntil (or prefs changed under us): still paused → just re-plan, fire nothing.
        if let pauseUntil = prefs.pauseUntil, pauseUntil > now {
            arm()
            return
        }

        let due = planner.dueGroups(events: store.events, preferences: prefs, state: state, now: now)
        // Focus/DND is global: honor it once for this fire, unless the user opted to alert anyway
        // ("Ignorar Focus" ON ⇒ respectFocus == false).
        let focusActive = prefs.respectFocus && focus.isActive()

        for group in due {
            // Consume this instant regardless of whether we present, so it can never re-fire in a loop.
            for event in group.events {
                state.markFired(SnoozeState.Key(eventID: event.id, stage: group.stage))
            }

            if focusActive {
                // F-052: respect Focus by NOT taking over the screen. Downgrade the intrusive
                // T-1 overlay to a silent notification; the T-5 notify is already a notification,
                // so present it normally (its .timeSensitive level is the intended heads-up).
                switch group.stage {
                case .overlay: presenter?.presentSilentNotification(group)
                case .notify:  presenter?.present(group)
                }
                continue
            }

            presenter?.present(group)
        }

        arm()
    }
}
