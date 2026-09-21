// OWNER: AlertUI module. This whole folder (Sources/AlertUI) belongs to the AlertUI builder.
// Files: AlertPresenter.swift, AlertPanel.swift, AlertOverlayView.swift, NotificationService.swift,
// AlertSoundPlayer.swift. Depends on Core ONLY.
//
// AlertPresenter is the AlertPresenting implementation: routes notify(T-5)→UNUserNotification and
// overlay(T-1)→on-demand NSPanel(s) at screen-saver (fullscreen) or floating level; plays AlertSound.
// User actions route back to AlertScheduling (held weakly to avoid a retain cycle with the Scheduler).
//
// F-064: the overlay reads `Preferences.overlayOptions` at the moment it is BUILT — the SAME code
// path for the real overlay and the test overlay (both go through `showOverlay`). Options are read
// only on fire (and on an explicit re-apply while an overlay is up); NO timer/observer/live view
// exists at idle, so the idle footprint does not regress.
//
// PERF (research/03): overlay panels are created ON FIRE and FULLY DESTROYED on dismiss — no
// retained hidden windows. contentViewController is niled before close() so the SwiftUI host is
// released; the per-second countdown timer, key monitor, space observer and (optional) auto-close
// timer live only while the overlay is up.
import AppKit
import SwiftUI
import Core

@MainActor
public final class AlertPresenter: @MainActor AlertPresenting {

    /// Set by the composition root after the Scheduler is built (breaks the Presenter↔Scheduler cycle).
    public weak var scheduler: AlertScheduling? {
        didSet { notificationService.scheduler = scheduler }
    }

    /// Supplies the current Core `Preferences` (chosen sound + F-064 overlay options). AlertUI depends
    /// on Core only, so the composition root wires this to the Prefs module's store, e.g.
    /// `presenter.preferencesProvider = { preferencesStore.preferences }`.
    public var preferencesProvider: () -> Preferences = { .default }

    private let notificationService = NotificationService()
    private let soundPlayer = AlertSoundPlayer()

    // Overlay state — non-nil only while the T-1 overlay is on screen.
    private var panels: [AlertPanel] = []
    private var overlayModel: AlertOverlayModel?
    private var keyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var autoCloseTimer: DispatchSourceTimer?
    /// The options the on-screen panels were built with — used to detect STRUCTURAL changes on a
    /// live re-apply (mode/monitors/position/auto-close), which require rebuilding the panels.
    private var currentOptions: OverlayOptions?
    /// Digit-key → snooze slot map for the CURRENT overlay (F-064: shortcuts follow the values).
    private var snoozeKeyMap: [Character: SnoozeInterval] = [:]

    public init() {}

    /// Register the UN category and request authorization. Call once at launch from the composition root.
    public func registerNotifications() {
        notificationService.registerCategories()
    }

    // MARK: - AlertPresenting

    public func present(_ group: AlertGroup) {
        switch group.stage {
        case .notify:
            notificationService.present(group)
        case .overlay:
            showOverlay(group)
        }
    }

    /// F-052: overlay downgraded to a silent notification while a Focus mode is active.
    public func presentSilentNotification(_ group: AlertGroup) {
        notificationService.presentSilent(group)
    }

    public func dismissActiveOverlay() {
        tearDownOverlay()
    }

    /// F-064: re-apply the current overlay options WITHOUT relaunching. No-op unless an overlay is
    /// up. Called by the composition root from its existing Preferences observer, so it adds no idle
    /// observer of its own. Content/appearance changes re-render live via the published `options`;
    /// structural changes (mode/monitors/position/auto-close) rebuild the panels in place.
    public func reapplyOverlayOptions() {
        guard let model = overlayModel else { return }
        let new = preferencesProvider().overlayOptions
        model.options = new                       // drives the live content/appearance re-render
        snoozeKeyMap = Self.makeSnoozeKeyMap(new)  // keep keyboard shortcuts following the values

        let old = currentOptions
        let structural = old == nil
            || old!.mode != new.mode
            || old!.monitors != new.monitors
            || old!.floatingCorner != new.floatingCorner
            || old!.floatingMargin != new.floatingMargin
        if structural {
            rebuildPanels(model: model, options: new)
        }
        if old?.autoCloseSeconds != new.autoCloseSeconds {
            scheduleAutoClose(seconds: new.autoCloseSeconds)
        }
        currentOptions = new
    }

    // MARK: - Overlay lifecycle

    private func showOverlay(_ group: AlertGroup) {
        // Only one overlay at a time — replace any existing one.
        tearDownOverlay()

        let options = preferencesProvider().overlayOptions
        let model = AlertOverlayModel(group: group, options: options)
        wireActions(model)
        model.start()
        overlayModel = model
        currentOptions = options
        snoozeKeyMap = Self.makeSnoozeKeyMap(options)

        rebuildPanels(model: model, options: options)

        installKeyMonitor()
        installSpaceObserver()
        scheduleAutoClose(seconds: options.autoCloseSeconds)

        // GROUP 4: independent volume + repeat-until-interaction (both read here, on fire).
        soundPlayer.play(preferencesProvider().sound, volume: options.volume, repeatSeconds: options.soundRepeatSeconds)
    }

    /// Build (or rebuild) the on-screen panels for the given mode/monitors/position. Tears down only
    /// the panels — the model, sound, key monitor, space observer and countdown timer are untouched,
    /// so a live re-apply does not restart the sound or reset the countdown.
    private func rebuildPanels(model: AlertOverlayModel, options: OverlayOptions) {
        for panel in panels {
            panel.contentViewController = nil
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()

        let screens = Self.targetScreens(for: options)
        switch options.mode {
        case .fullscreen:
            // ONE panel per target screen — all fire simultaneously (research/02: multi-monitor
            // consistency is the #1 user complaint about "In Your Face").
            for screen in screens {
                let panel = makePanel(frame: screen.frame, level: .screenSaver, model: model)
                panel.setFrame(screen.frame, display: true)
                panel.orderFrontRegardless()
                panels.append(panel)
            }
        case .floating:
            // ONE compact non-activating floating panel on the target screen, fixed size, anchored.
            let screen = screens.first ?? NSScreen.main ?? NSScreen.screens.first!
            let size = NSSize(width: 440, height: 300)
            let frame = Self.floatingFrame(size: size, in: screen.visibleFrame,
                                           corner: options.floatingCorner, margin: options.floatingMargin)
            let panel = makePanel(frame: frame, level: .floating, model: model)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Make the panel on the active screen key so keyDown reaches our monitor (Enter/1/3/5/Esc).
        if let keyPanel = panels.first(where: { $0.screen == NSScreen.main }) ?? panels.first {
            keyPanel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel(frame: NSRect, level: NSWindow.Level, model: AlertOverlayModel) -> AlertPanel {
        let panel = AlertPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false   // we own teardown explicitly
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = (level == .floating)   // the compact floating card gets a drop shadow
        panel.contentViewController = NSHostingController(rootView: AlertOverlayView(model: model))
        return panel
    }

    private func wireActions(_ model: AlertOverlayModel) {
        // Each action routes to the Scheduler, then tears the overlay down. The Scheduler owns
        // opening the join link (join), rescheduling (snooze), suppression (markAlreadyInCall) and
        // rearming.
        model.onJoin = { [weak self] event in
            self?.scheduler?.join(event)
            self?.tearDownOverlay()
        }
        model.onSnooze = { [weak self] interval in
            guard let self, let group = self.overlayModel?.group else { return }
            self.scheduler?.snooze(group, by: interval)
            self.tearDownOverlay()
        }
        model.onDismiss = { [weak self] in
            guard let self, let group = self.overlayModel?.group else { return }
            self.scheduler?.dismiss(group)
            self.tearDownOverlay()
        }
        model.onAlreadyInCall = { [weak self] event in
            self?.scheduler?.markAlreadyInCall(event)
            self?.tearDownOverlay()
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.overlayModel else { return event }
            switch event.keyCode {
            case 36, 76:            // Return / keypad Enter → Entrar
                model.onJoin(model.primaryEvent); return nil
            case 49:                // Space → já estou na call (primary event)
                model.onAlreadyInCall(model.primaryEvent); return nil
            case 53:                // Esc → Depois
                model.onDismiss(); return nil
            default:
                // F-064: snooze digit keys follow the configured minute values (1…9 per slot).
                if let ch = event.charactersIgnoringModifiers?.first,
                   let slot = self.snoozeKeyMap[ch] {
                    model.onSnooze(slot); return nil
                }
                return event
            }
        }
    }

    private func installSpaceObserver() {
        // Re-assert the panels when the active Space changes (e.g. user switches to a full-screen
        // app after the overlay appears) — research/02 §"Handling newly created Spaces".
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panels.forEach { $0.orderFrontRegardless() }
            }
        }
    }

    /// GROUP 3: auto-close after X seconds (0 == never). Treated as "Depois" (same path as Esc), so
    /// a real event is recorded in history normally. The timer lives ONLY while the overlay is up.
    private func scheduleAutoClose(seconds: Int) {
        autoCloseTimer?.cancel()
        autoCloseTimer = nil
        guard seconds > 0, overlayModel != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Double(seconds), leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.overlayModel?.onDismiss() }
        }
        t.resume()
        autoCloseTimer = t
    }

    private func tearDownOverlay() {
        guard overlayModel != nil || !panels.isEmpty else { return }

        autoCloseTimer?.cancel()
        autoCloseTimer = nil

        overlayModel?.stop()
        overlayModel = nil
        currentOptions = nil
        snoozeKeyMap = [:]

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil

        soundPlayer.stop()

        for panel in panels {
            panel.contentViewController = nil   // release the SwiftUI host — no retained view
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    // MARK: - Geometry / options helpers

    /// Screens the overlay covers, per the `monitors` option. For floating, only `.first` is used.
    private static func targetScreens(for options: OverlayOptions) -> [NSScreen] {
        switch options.monitors {
        case .all:
            return NSScreen.screens.isEmpty ? [] : NSScreen.screens
        case .primary:
            if let main = NSScreen.main { return [main] }
            return Array(NSScreen.screens.prefix(1))
        case .mouse:
            let mouse = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return [s] }
            if let main = NSScreen.main { return [main] }
            return Array(NSScreen.screens.prefix(1))
        }
    }

    /// Anchor `size` inside `area` (a screen's visibleFrame) at the chosen corner with `margin`.
    private static func floatingFrame(size: NSSize, in area: NSRect, corner: OverlayCorner, margin: Double) -> NSRect {
        let m = CGFloat(margin)
        let x: CGFloat, y: CGFloat
        switch corner {
        case .topLeft:      x = area.minX + m;                    y = area.maxY - size.height - m
        case .topRight:     x = area.maxX - size.width - m;       y = area.maxY - size.height - m
        case .bottomLeft:   x = area.minX + m;                    y = area.minY + m
        case .bottomRight:  x = area.maxX - size.width - m;       y = area.minY + m
        case .center:       x = area.midX - size.width / 2;       y = area.midY - size.height / 2
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Map single-digit configured snooze minutes to the 3 positional slots (.one/.three/.five are
    /// just slot tokens now — the Scheduler resolves each to the configured minutes). First slot
    /// wins on a duplicate digit; multi-digit values (10+) are click/legend-only, no key.
    private static func makeSnoozeKeyMap(_ options: OverlayOptions) -> [Character: SnoozeInterval] {
        let slots: [SnoozeInterval] = [.one, .three, .five]
        var map: [Character: SnoozeInterval] = [:]
        for (i, minutes) in options.normalizedSnoozeMinutes.enumerated() where minutes >= 1 && minutes <= 9 {
            let ch = Character("\(minutes)")
            if map[ch] == nil { map[ch] = slots[i] }
        }
        return map
    }
}
