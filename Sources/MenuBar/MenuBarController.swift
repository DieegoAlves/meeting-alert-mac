// OWNER: MenuBar module — NSStatusItem, dynamic title, NSPopover lifecycle, scoped countdown.
// NSPopoverDelegate starts/stops the per-second clock so it only runs while the popover is open.
import AppKit
import SwiftUI
import Core

@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {

    // Notifications AppDelegate observes to wire preferences/pause logic.
    public static let openPreferencesNotification = Notification.Name("MenuBar.openPreferences")
    public static let pauseAlertsForOneHourNotification = Notification.Name("MenuBar.pauseAlertsForOneHour")
    /// "Conectar Google": request an explicit interactive OAuth sign-in.
    public static let connectGoogleNotification = Notification.Name("MenuBar.connectGoogle")
    /// F-063: "Testar alerta…": request the App layer to fire the real overlay with a test event.
    public static let testAlertNotification = Notification.Name("MenuBar.testAlert")

    private let store: EventStore
    private let scheduler: AlertScheduling
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var historyController: HistoryWindowController?
    private let clock = MenuBarClock()

    // Title timer always at 60 s. Switches to 1 s only while popover is visible.
    private var titleTimer: DispatchSourceTimer?
    private var currentTimerInterval: TimeInterval = 60
    private var isPopoverOpen = false
    private var storeObserver: NSObjectProtocol?

    // F-062: transient-dismiss plumbing. These exist ONLY while the popover is open and are
    // torn down in popoverDidClose, so nothing leaks and no monitor burns idle CPU when the
    // panel is hidden.
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// When a transient popover auto-closes because the user clicked the status item itself, the
    /// button action fires right after — this timestamp lets `handleClick` swallow that trailing
    /// open so the same click doesn't immediately reopen the panel (correct toggle).
    private var lastAutoCloseAt: Date = .distantPast

    public init(store: EventStore, scheduler: AlertScheduling) {
        self.store = store
        self.scheduler = scheduler
        super.init()
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "Meeting Alert"
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        statusItem = item

        storeObserver = NotificationCenter.default.addObserver(
            forName: EventStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }

        let (title, _) = computeTitle()
        statusItem?.button?.title = title
        armTitleTimer(interval: 60)
    }

    // MARK: - NSPopoverDelegate (scope per-second clock to popover visibility)

    public func popoverWillShow(_ notification: Notification) {
        clock.start()
        isPopoverOpen = true
        installDismissMonitors()   // F-062: arm outside-click / Esc / focus-loss dismissal
        // Re-evaluate interval: may switch to 1 s if < 60 s to next meeting.
        refreshTitle()
    }

    public func popoverDidClose(_ notification: Notification) {
        clock.stop()
        isPopoverOpen = false
        lastAutoCloseAt = Date()    // F-062: mark for the toggle guard in handleClick
        removeDismissMonitors()     // F-062: tear everything down — no leak, no idle monitor
        // Drop back to 60 s — no per-second wakeups when popover is hidden.
        if currentTimerInterval != 60 {
            currentTimerInterval = 60
            armTitleTimer(interval: 60)
        }
    }

    // MARK: - F-062: transient dismissal (outside click / Esc / focus loss)

    /// Armed the instant the popover shows; every piece is removed again in `removeDismissMonitors`.
    private func installDismissMonitors() {
        // (a) Clicks in ANOTHER app or on the desktop — events NOT delivered to us — close the
        // panel. A global monitor does NOT fire for clicks on our own status-item button (those
        // go to us), so the icon keeps toggling correctly without a double-open.
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover?.performClose(nil) }
            }
        }
        // (b) Esc while the panel is key. Local monitor only fires while our app is active (we
        // activate on show), and consumes the Esc so it doesn't beep.
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return event }   // 53 = Esc
                MainActor.assumeIsolated { self?.popover?.performClose(nil) }
                return nil
            }
        }
        // (c) App loses focus (Cmd-Tab, clicking another app's window) → close.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover?.performClose(nil) }
            }
        }
    }

    private func removeDismissMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    // MARK: - Popover (lazy creation — avoids allocating SwiftUI hosting controller at launch)

    private func makePopover() -> NSPopover {
        if let existing = popover { return existing }
        let contentView = MenuBarView(
            store: store,
            clock: clock,
            syncStatus: SyncStatusCenter.shared,
            scheduler: scheduler,
            openHistory: { [weak self] in self?.openHistory() },
            postPause: {
                NotificationCenter.default.post(name: Self.pauseAlertsForOneHourNotification, object: nil)
            },
            postPreferences: {
                NotificationCenter.default.post(name: Self.openPreferencesNotification, object: nil)
            },
            postConnectGoogle: {
                NotificationCenter.default.post(name: Self.connectGoogleNotification, object: nil)
            },
            postTestAlert: {
                NotificationCenter.default.post(name: Self.testAlertNotification, object: nil)
            }
        )
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 480)
        pop.behavior = .transient
        pop.delegate = self
        pop.contentViewController = NSHostingController(rootView: contentView)
        popover = pop
        return pop
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let pop = makePopover()
        guard let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(nil)
            return
        }
        // F-062: if this very click just auto-dismissed a transient popover, don't reopen it —
        // clicking the icon while open must close (and stay closed), not toggle back on.
        if Date().timeIntervalSince(lastAutoCloseAt) < 0.3 { return }
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // F-062: activate so the popover becomes key — required for Esc, AppKit's own transient
        // outside-click dismissal, and didResignActive to work for this .accessory (menu-bar) app,
        // which is otherwise inactive when a status-item popover appears. No Dock icon appears.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openHistory() {
        if historyController == nil {
            historyController = HistoryWindowController(store: store)
        }
        historyController?.showWindow()
    }

    // MARK: - Status title (adaptive-frequency countdown)

    private func refreshTitle() {
        let (title, needsSec) = computeTitle()
        statusItem?.button?.title = title

        // Only use 1 s while the popover is visible; never wake up every second at idle.
        let newInterval: TimeInterval = (needsSec && isPopoverOpen) ? 1 : 60
        guard newInterval != currentTimerInterval else { return }
        currentTimerInterval = newInterval
        armTitleTimer(interval: newInterval)
    }

    private func computeTitle() -> (title: String, needsSecondTick: Bool) {
        let now = Date()
        if let next = store.upcoming.first {
            let diff = next.start.timeIntervalSince(now)
            if diff < 60 {
                return ("⏱ \(max(0, Int(diff)))s", true)
            } else if diff < 3600 {
                return ("⏰ \(Int(diff / 60))m", false)
            } else {
                let h = Int(diff / 3600)
                let m = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
                return (m > 0 ? "⏰ \(h)h\(m)m" : "⏰ \(h)h", false)
            }
        } else if !store.active.isEmpty {
            return ("● Reunião", false)
        } else {
            return ("⏰", false)
        }
    }

    private func armTitleTimer(interval: TimeInterval) {
        titleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let leeway: DispatchTimeInterval = interval < 2 ? .milliseconds(100) : .milliseconds(500)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in self?.refreshTitle() }
        t.resume()
        titleTimer = t
    }

    deinit {
        titleTimer?.cancel()
        if let obs = storeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // F-062: safety net — never leave a dismissal monitor/observer installed.
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }
}
