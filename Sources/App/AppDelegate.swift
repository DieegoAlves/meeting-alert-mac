// OWNER: App module (composition root). Builds the object graph and wires modules together.
// Owns NO domain logic — every concrete class lives in its own module.
import AppKit
import Combine
import Core
import Auth
import Sync
import AlertUI
import MenuBar
import Scheduler
import Prefs

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retained graph (composition root owns the lifetimes).
    private let store = EventStore.shared
    private let preferencesStore = PreferencesStore()

    private var auth: GoogleAuth!
    private var syncService: CalendarSyncService!
    private var presenter: AlertPresenter!
    private var scheduler: AlertScheduler!
    private var menuBar: MenuBarController!

    // Alert-pipeline observers (Scheduler owns the alert loop; App only wires the triggers).
    private var cancellables = Set<AnyCancellable>()
    private var storeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pauseObserver: NSObjectProtocol?
    private var clientIDSavedObserver: NSObjectProtocol?
    private var connectGoogleObserver: NSObjectProtocol?
    private var testAlertMenuObserver: NSObjectProtocol?
    private var testAlertPrefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Persisted state.
        preferencesStore.load()
        store.load()

        // 2. Build the graph.
        auth = GoogleAuth()
        syncService = CalendarSyncService(auth: auth, store: store)
        syncService.preferences = preferencesStore.preferences   // seed filter/interval before first sync

        presenter = AlertPresenter()
        scheduler = AlertScheduler(store: store, presenter: presenter, preferencesStore: preferencesStore)
        presenter.scheduler = scheduler   // break the Presenter↔Scheduler cycle (weak on both sides)
        presenter.preferencesProvider = { [preferencesStore] in preferencesStore.preferences }
        presenter.registerNotifications()

        menuBar = MenuBarController(store: store, scheduler: scheduler)

        // 2a. Arm the Preferences window: listens for MenuBar's "Preferências…" notification.
        PreferencesWindowController.setup(store: preferencesStore)

        // 3. Wire the runtime alert pipeline: EventStore / Preferences / wake all rearm the Scheduler.
        wireAlertPipeline()

        // 4. Start subsystems + install the (placeholder) menu-bar item.
        menuBar.install()
        scheduler.start()

        // DEMO MODE is an explicit opt-in (MEETINGALERT_DEMO=1) that is force-disabled whenever
        // an OAuth client ID is configured (DemoFixtures.isEnabled). In demo mode we seed fake
        // events and skip real sync; otherwise we run real sync and, if a client ID is present,
        // kick off OAuth so real events populate without the user hunting for a button.
        if DemoFixtures.isEnabled {
            store.replaceAll(DemoFixtures.events())
            scheduler.rearmForNextAlert()   // arm the T-1 overlay for the ~90s demo event
        } else {
            enterRealMode()
        }
    }

    /// Real (non-demo) mode: evict any demo-origin events left over from a previous demo run,
    /// start Google sync, and open the OAuth consent flow if a client ID is set but we're not
    /// signed in yet. Idempotent — safe to call again when the client ID is (re)saved at runtime.
    private func enterRealMode() {
        purgeDemoEventsIfAny()
        // stop()+start() guarantees a single clean set of scheduler/wake/network observers even
        // if sync was already running, and triggers one immediate sync pass.
        syncService.stop()
        syncService.start()
        startOAuthIfNeeded()
    }

    /// Remove fake demo events from the store/cache so they never linger once real mode is on.
    /// Real events are untouched — only events tagged with the reserved demo calendar id go.
    /// (Incremental sync alone would never remove them: the demo calendar is never in Google's
    /// calendar list, so it never gets the full-resync eviction pass.)
    private func purgeDemoEventsIfAny() {
        let demoIDs = store.events.filter(DemoFixtures.isDemoEvent).map(\.id)
        guard !demoIDs.isEmpty else { return }
        store.apply(upserts: [], removedIDs: demoIDs)
    }

    /// If a client ID is configured but there is no stored credential yet, open the Google
    /// consent flow in the browser. Once authorized, nudge an immediate sync.
    private func startOAuthIfNeeded() {
        guard DemoFixtures.hasClientID else { return }
        // F-059: the Desktop-app flow REQUIRES a client secret (F-057). Without one saved, the
        // code→token exchange ALWAYS fails ("client_secret is missing"), so auto-opening OAuth just
        // re-shows a doomed browser login. Skip the automatic sign-in until the secret exists; the
        // user pastes it in Preferences (→ enterRealMode re-runs this) or uses "Conectar Google"
        // explicitly. This stops the "keeps asking me to log in" churn when the secret isn't set yet.
        // F-065: a secret is available either embedded in the build or pasted by the user.
        guard OAuthClientConfig.hasUsableClientSecret else {
            NSLog("[MeetingAlert] Sign-in automático adiado: Client Secret ainda não configurado (Preferências → Google OAuth).")
            return
        }
        Task { [auth, syncService] in
            guard let auth, let syncService else { return }
            if await auth.isAuthorized { return }   // refresh token already present → sync handles it
            do {
                try await auth.signIn()             // opens the browser (loopback OAuth PKCE)
                syncService.requestImmediateSync()
            } catch {
                NSLog("[MeetingAlert] OAuth automático falhou: \(error.localizedDescription)")
            }
        }
    }

    /// Explicit "Conectar Google" action (menu / re-save): always runs the interactive sign-in,
    /// even when a stale credential exists, so the user can reconnect on demand.
    private func connectGoogle() {
        Task { [auth, syncService] in
            guard let auth, let syncService else { return }
            do {
                try await auth.signIn()
                syncService.requestImmediateSync()
            } catch {
                NSLog("[MeetingAlert] Conectar Google falhou: \(error.localizedDescription)")
            }
        }
    }

    /// Every input that changes the next alert instant → `scheduler.rearmForNextAlert()`.
    private func wireAlertPipeline() {
        // New sync landed in the store.
        storeObserver = NotificationCenter.default.addObserver(
            forName: EventStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.rearmForNextAlert() }
        }

        // Preferences changed (lead times, pause, focus toggle, calendar filter).
        preferencesStore.$preferences
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                MainActor.assumeIsolated {
                    // If the poll interval changed, rebuild NSBackgroundActivityScheduler so the
                    // new cadence takes effect immediately (F-023: interval was frozen at launch).
                    let intervalChanged = self?.syncService.preferences.syncInterval != prefs.syncInterval
                    self?.syncService.preferences = prefs
                    if intervalChanged {
                        self?.syncService.stop()
                        self?.syncService.start()
                    }
                    self?.scheduler.rearmForNextAlert()
                    // F-064: if an overlay (real or test) is currently up, re-apply the new overlay
                    // options live without relaunching. No-op when no overlay is shown, so this adds
                    // no idle work — it rides the Preferences observer that already exists here.
                    self?.presenter.reapplyOverlayOptions()
                }
            }
            .store(in: &cancellables)

        // MenuBar "Pausar alertas por 1h": set pauseUntil; the Preferences observer above rearms.
        pauseObserver = NotificationCenter.default.addObserver(
            forName: MenuBarController.pauseAlertsForOneHourNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preferencesStore.update { $0.pauseUntil = Date().addingTimeInterval(3600) }
            }
        }

        // Sleep/wake: disarm before sleep (avoid a spurious fire), recompute on wake (research/03).
        let ws = NSWorkspace.shared.notificationCenter
        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.disarm() }
        }
        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.rearmForNextAlert() }
        }

        // Client ID (re)saved in Preferences: force real mode now — purge demo events, (re)start
        // sync, and open OAuth — so a freshly pasted client ID takes effect without relaunch.
        clientIDSavedObserver = NotificationCenter.default.addObserver(
            forName: PreferencesEvents.clientIDSavedNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                // F-058: persist a freshly-entered client secret to the Keychain (Prefs hands it
                // over in-memory via userInfo; it never touches UserDefaults/JSON).
                if let secret = note.userInfo?[PreferencesEvents.clientSecretKey] as? String {
                    GoogleAuth.saveClientSecret(secret)
                }
                self?.enterRealMode()
            }
        }

        // MenuBar "Conectar Google": explicit interactive sign-in on demand.
        connectGoogleObserver = NotificationCenter.default.addObserver(
            forName: MenuBarController.connectGoogleNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectGoogle() }
        }

        // F-063 "Testar alerta" — from the menu bar OR Preferences → fire the REAL overlay with a
        // synthetic test event (same present() path as a real T-1 alert; touches no events/history).
        testAlertMenuObserver = NotificationCenter.default.addObserver(
            forName: MenuBarController.testAlertNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.fireTestAlert() }
        }
        testAlertPrefsObserver = NotificationCenter.default.addObserver(
            forName: PreferencesEvents.testAlertNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.fireTestAlert() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncService?.stop()
        store.persist()
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
        if let clientIDSavedObserver { NotificationCenter.default.removeObserver(clientIDSavedObserver) }
        if let connectGoogleObserver { NotificationCenter.default.removeObserver(connectGoogleObserver) }
        if let testAlertMenuObserver { NotificationCenter.default.removeObserver(testAlertMenuObserver) }
        if let testAlertPrefsObserver { NotificationCenter.default.removeObserver(testAlertPrefsObserver) }
        let ws = NSWorkspace.shared.notificationCenter
        if let sleepObserver { ws.removeObserver(sleepObserver) }
        if let wakeObserver { ws.removeObserver(wakeObserver) }
    }
}
