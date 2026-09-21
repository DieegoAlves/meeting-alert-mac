// OWNER: Sync module. Google Calendar incremental sync → EventStore.
// Two lanes per ARCHITECTURE:
//   Lane 1 (windowed)     — full resync of [now-7d … end-of-tomorrow], used on initial sync / 410
//   Lane 2 (incremental)  — syncToken delta (showDeleted=true, no time bounds), used every poll
// Scheduling: NSBackgroundActivityScheduler at preferences.syncInterval (default 60 s).
// Wakeup triggers: NSWorkspace.didWakeNotification + NWPathMonitor.satisfied.
import Foundation
import AppKit    // NSWorkspace.didWakeNotification
import Network   // NWPathMonitor
import Core

// MARK: - Sync-level errors (F-057)

/// Non-HTTP sync conditions surfaced to the status center.
enum CalendarSyncError: Error {
    case notAuthorized   // no stored credential yet
}

// MARK: - Sync state persistence (syncToken per calendarId)

private struct SyncState: Codable, Equatable {
    var tokens: [String: String] = [:]        // calendarId → nextSyncToken
    var lastFullSync: [String: Date] = [:]    // calendarId → last full/windowed resync (F-040 daily safety net)

    enum CodingKeys: String, CodingKey { case tokens, lastFullSync }

    init() {}

    // Tolerant decode so a pre-existing sync_state.json (written before `lastFullSync`
    // existed) still loads and keeps its syncTokens instead of forcing a cold full resync.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
        lastFullSync = try c.decodeIfPresent([String: Date].self, forKey: .lastFullSync) ?? [:]
    }

    static var url: URL {
        AppPaths.appSupportDirectory.appendingPathComponent("sync_state.json")
    }

    static func load() -> SyncState {
        guard let data  = try? Data(contentsOf: url),
              let state = try? JSONDecoder.meetingAlert.decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    func save() {
        try? AppPaths.ensureAppSupportDirectory()
        try? JSONEncoder.meetingAlert.encode(self).write(to: Self.url, options: .atomic)
    }
}

// MARK: - CalendarSyncService

/// Orchestrates periodic + event-driven Google Calendar sync.
/// Public API is non-async; sync work runs inside Swift Tasks.
public final class CalendarSyncService: @unchecked Sendable {
    private let auth: AuthProviding
    private let store: EventStore
    private let api  = GoogleCalendarAPI()

    // F-020: `preferences` is written on the main thread (AppDelegate) and read from
    // background sync tasks, so it must be serialized. Public API is unchanged — still a
    // settable `var preferences` — but storage is guarded by `prefsQueue`.
    private let prefsQueue = DispatchQueue(label: "com.meetingalert.sync.prefs")
    private var _preferences: Preferences = .default
    public var preferences: Preferences {
        get { prefsQueue.sync { _preferences } }
        set {
            let intervalChanged = prefsQueue.sync { () -> Bool in
                let changed = _preferences.syncInterval != newValue.syncInterval
                _preferences = newValue
                return changed
            }
            // F-023: apply the new cadence to the live scheduler instead of waiting for relaunch.
            if intervalChanged { reconfigureSchedulerIfRunning() }
        }
    }

    // Internal mutable state — all mutations serialized on `stateQueue`.
    private let stateQueue = DispatchQueue(label: "com.meetingalert.sync.state", qos: .utility)
    private var _syncState: SyncState = .init()
    private var syncState: SyncState {
        get { stateQueue.sync { _syncState } }
        set { stateQueue.sync { _syncState = newValue } }
    }

    // F-020: `backgroundScheduler` is mutated from start()/stop() and from the preferences
    // setter (F-023 re-arm), and `currentSyncTask` from the main thread (wake observer) and
    // the network-monitor queue — both need serialized access.
    private let schedulerLock = NSLock()
    private var backgroundScheduler: NSBackgroundActivityScheduler?
    private var networkMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private let taskLock = NSLock()
    private var currentSyncTask: Task<Void, Never>?
    private var lastNetworkStatus: NWPath.Status = .unsatisfied

    public init(auth: AuthProviding, store: EventStore) {
        self.auth = auth
        self.store = store
        _syncState = SyncState.load()
    }

    // MARK: - Lifecycle

    public func start() {
        setupBackgroundScheduler()
        setupWakeObserver()
        setupNetworkMonitor()
        triggerSync()
    }

    public func stop() {
        schedulerLock.lock()
        backgroundScheduler?.invalidate()
        backgroundScheduler = nil
        schedulerLock.unlock()

        networkMonitor?.cancel()
        networkMonitor = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }

        taskLock.lock()
        currentSyncTask?.cancel()
        currentSyncTask = nil
        taskLock.unlock()
    }

    // MARK: - Sync trigger (non-async entry point)

    /// Fire an immediate sync pass outside the poll cadence — e.g. right after an interactive
    /// Google sign-in, so real events appear without waiting for the next scheduled poll.
    public func requestImmediateSync() {
        triggerSync()
    }

    private func triggerSync() {
        // F-020: serialize the cancel-and-replace so the wake observer (main) and the
        // network monitor queue can't corrupt `currentSyncTask` when they fire together.
        taskLock.lock()
        currentSyncTask?.cancel()
        currentSyncTask = Task { [weak self] in
            await self?.syncNow()
        }
        taskLock.unlock()
    }

    // MARK: - Core sync cycle

    public func syncNow() async {
        guard await auth.isAuthorized else {
            NSLog("[MeetingAlert] Sync skipped: não autorizado (nenhum token). Use 'Conectar Google'.")
            await recordFailure(CalendarSyncError.notAuthorized)
            return
        }
        do {
            try await runSyncPass()
        } catch CalendarAPIError.insufficientScope(let message) {
            // F-060: the stored token's granted scope is too narrow (e.g. an old `events.readonly`
            // token calling calendarList.list). Retrying is pointless — CLEAR the credential so the
            // app stops reusing the dead token, and surface an actionable "Reconectar" message in
            // Preferences. signOut() also revokes the stale grant (best-effort) and flips the status
            // line to disconnected. Never fail silently.
            NSLog("[MeetingAlert] Sync 403 insufficientPermissions — limpando credencial e exigindo reconexão: \(message)")
            try? await auth.signOut()
            await recordFailure(CalendarAPIError.insufficientScope(message: message))
        } catch CalendarAPIError.unauthenticated {
            // F-042: an HTTP 401 means the cached access token was rejected (revocation,
            // scope/consent change, clock skew). Bust the Auth token cache so the next
            // validAccessToken() re-fetches via the refresh token, then retry exactly once.
            // Without this the same rejected token is reused every poll until it expires
            // (~59 min) and sync stalls silently.
            await auth.invalidateAccessToken()
            do {
                try await runSyncPass()
            } catch {
                // Still failing after a forced token refresh — treat as transient; the next
                // scheduled poll retries. (A dead refresh token is handled in GoogleAuth per
                // F-041: it wipes the credential and surfaces re-auth via Preferences.)
                NSLog("[MeetingAlert] Sync falhou após refresh de token: \(error.localizedDescription) (\(error))")
                await recordFailure(error)
            }
        } catch {
            // Auth/network errors are transient; next scheduled poll will retry.
            NSLog("[MeetingAlert] Sync falhou: \(error.localizedDescription) (\(error))")
            await recordFailure(error)
        }
    }

    /// One full sync pass: fresh token → calendar list → filter to enabled → per-calendar sync.
    /// Propagates CalendarAPIError.unauthenticated so `syncNow()` can bust the token cache (F-042).
    private func runSyncPass() async throws {
        await MainActor.run { SyncStatusCenter.shared.recordAttempt() }
        let token = try await auth.validAccessToken()
        let calendars = try await api.fetchCalendarList(token: token)
        publishCatalog(calendars)                    // F-053: surface calendars to the Prefs picker
        let enabled = filterCalendars(calendars)     // F-053: sync only enabled calendars
        try await syncCalendars(enabled, token: token)
        // F-057: record the outcome (time + event count) so Prefs/MenuBar can show it and a
        // "login OK but zero events" state is explained rather than silent.
        let eventCount = await MainActor.run { self.store.events.count }
        await MainActor.run {
            SyncStatusCenter.shared.recordSuccess(calendarCount: enabled.count, eventCount: eventCount)
        }
        NSLog("[MeetingAlert] Sync OK: \(calendars.count) calendário(s), \(enabled.count) habilitado(s), \(eventCount) evento(s) na janela.")
    }

    /// F-057: map a sync error to an exact, user-facing message (+ optional API-enable URL) and
    /// publish it to the shared status center so it surfaces in Preferences and the menu.
    private func recordFailure(_ error: Error) async {
        let (message, enableURL) = Self.describe(error)
        await MainActor.run { SyncStatusCenter.shared.recordFailure(message, enableAPIURL: enableURL) }
    }

    static func describe(_ error: Error) -> (message: String, enableURL: String?) {
        switch error {
        case CalendarAPIError.apiDisabled(let m, let url):
            return ("A Google Calendar API não está habilitada neste projeto. \(m)", url)
        case CalendarAPIError.insufficientScope(let m):
            return ("Permissão insuficiente do Google (\(m)). Reconecte em 'Conectar Google' para conceder acesso de leitura ao Calendar.", nil)
        case CalendarAPIError.forbidden(let m):
            return ("Acesso negado pelo Google: \(m)", nil)
        case CalendarAPIError.rateLimited:
            return ("Google limitou a taxa (rate limit). Nova tentativa no próximo ciclo.", nil)
        case CalendarAPIError.unauthenticated:
            return ("Token rejeitado (HTTP 401). Reconecte em 'Conectar Google'.", nil)
        case CalendarAPIError.httpError(let code):
            return ("Erro HTTP \(code) do Google Calendar.", nil)
        case CalendarAPIError.invalidResponse:
            return ("Resposta inválida do Google Calendar.", nil)
        case CalendarSyncError.notAuthorized:
            return ("Não autorizado — use 'Conectar Google' em Preferências.", nil)
        default:
            return (error.localizedDescription, nil)
        }
    }

    // MARK: - Per-calendar sync (two-lane)

    private func syncCalendars(_ calendars: [CalendarListEntry], token: String) async throws {
        var upserts: [CalendarEvent] = []
        var removedIDs: [String] = []
        var updatedState = syncState
        let previousState = updatedState
        var fullySyncedCalendarIDs: Set<String> = []

        let now = Date()
        let dayAgo = now.addingTimeInterval(-86_400)

        for calendar in calendars {
            let calendarId = calendar.id
            let storedToken = updatedState.tokens[calendarId]
            let lastFull = updatedState.lastFullSync[calendarId]
            // F-040: full resync ONLY on a missing token, an HTTP 410, or the once-per-day
            // safety net — never as the reaction to a normal incremental change.
            let dailyRefreshDue = (lastFull == nil) || (lastFull! < dayAgo)

            if let syncToken = storedToken, !dailyRefreshDue {
                // Lane 2: incremental — upsert by event id, remove cancelled by event id.
                do {
                    let result = try await api.fetchIncrementalEvents(
                        calendarId: calendarId,
                        token: token,
                        syncToken: syncToken
                    )
                    let (ups, dels) = partition(result.events, calendarId: calendarId)
                    upserts.append(contentsOf: ups)
                    removedIDs.append(contentsOf: dels)
                    updatedState.tokens[calendarId] = result.nextSyncToken ?? syncToken
                } catch CalendarAPIError.syncTokenExpired {
                    // Lane 1: HTTP 410 GONE → full resync of THIS calendar only.
                    let result = try await fullWindowedSync(calendarId: calendarId, token: token)
                    upserts.append(contentsOf: result.events)
                    updatedState.tokens[calendarId] = result.syncToken
                    updatedState.lastFullSync[calendarId] = now
                    fullySyncedCalendarIDs.insert(calendarId)
                }
            } else {
                // Lane 1: initial full sync (no token yet) or the daily safety-net resync.
                let result = try await fullWindowedSync(calendarId: calendarId, token: token)
                upserts.append(contentsOf: result.events)
                updatedState.tokens[calendarId] = result.syncToken
                updatedState.lastFullSync[calendarId] = now
                fullySyncedCalendarIDs.insert(calendarId)
            }
        }

        // F-040 (6): persist syncTokens atomically only when they actually changed.
        if updatedState != previousState {
            syncState = updatedState
            updatedState.save()
        }

        // F-040: reconcile into EventStore by event id — NEVER replaceAll. replaceAll dumps
        // unchanged events from calendars still on the incremental lane (durable data loss).
        // For calendars that did a full resync this cycle, evict their stale events (present
        // in the store but absent from the fresh windowed fetch); all other calendars keep
        // everything they had.
        let resolvedUpserts = upserts
        let resolvedRemovals = removedIDs
        let fullCalendars = fullySyncedCalendarIDs

        await MainActor.run { [weak self] in
            guard let self else { return }

            let freshFullIDs = Set(resolvedUpserts
                .filter { fullCalendars.contains($0.calendarId) }
                .map { $0.id })

            var removals = Set(resolvedRemovals)
            for event in self.store.events where fullCalendars.contains(event.calendarId) {
                if !freshFullIDs.contains(event.id) {
                    removals.insert(event.id)   // stale in a fully-resynced calendar → evict
                }
            }

            // F-040 (6): only mutate the store (which triggers its debounced cache write)
            // when the merge actually changes something. EventStore.apply posts its change
            // notification, which is what re-arms the single alert timer and recomputes the
            // "Próximas / Já passaram" lists (F-040 (4)).
            guard !resolvedUpserts.isEmpty || !removals.isEmpty else { return }
            self.store.apply(upserts: resolvedUpserts, removedIDs: Array(removals))
        }
    }

    // MARK: - Windowed full sync (Lane 1)

    private struct WindowedResult {
        let events: [CalendarEvent]
        let syncToken: String?
    }

    private func fullWindowedSync(calendarId: String, token: String) async throws -> WindowedResult {
        let now = Date()
        let cal = Calendar.current
        let timeMin = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let timeMax: Date = {
            let startOfToday = cal.startOfDay(for: now)
            return cal.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        }()

        let result = try await api.fetchWindowedEvents(
            calendarId: calendarId,
            token: token,
            timeMin: timeMin,
            timeMax: timeMax
        )

        let events: [CalendarEvent] = result.events.compactMap { raw in
            guard var event = raw.toCalendarEvent(calendarId: calendarId) else { return nil }
            event.join = JoinResolver.resolve(dto: raw)
            return event
        }

        return WindowedResult(events: events, syncToken: result.syncToken)
    }

    // MARK: - Incremental partition (Lane 2)

    /// Splits incremental events into upserts (in-window, non-cancelled) and removed IDs.
    private func partition(
        _ raws: [RawEvent],
        calendarId: String
    ) -> (upserts: [CalendarEvent], removedIDs: [String]) {
        var upserts: [CalendarEvent] = []
        var removedIDs: [String] = []

        for raw in raws {
            if raw.isCancelled {
                removedIDs.append(raw.id)
            } else if var event = raw.toCalendarEvent(calendarId: calendarId) {
                event.join = JoinResolver.resolve(dto: raw)
                upserts.append(event)
            }
        }
        return (upserts, removedIDs)
    }

    // MARK: - Calendar filtering

    /// F-053: sync runs ONLY for enabled calendars. A calendar is enabled unless its id is in
    /// `disabledCalendarIDs` (empty == all enabled). The primary calendar is never in that set
    /// (the picker keeps it non-deselectable), so it always syncs.
    private func filterCalendars(_ calendars: [CalendarListEntry]) -> [CalendarListEntry] {
        let disabled = preferences.disabledCalendarIDs
        guard !disabled.isEmpty else { return calendars }
        return calendars.filter { !disabled.contains($0.id) }
    }

    /// F-053: publish the discovered calendars (id, name, primary, color) to the shared
    /// CalendarCatalog so the Prefs picker can render one checkbox per calendar.
    private func publishCatalog(_ calendars: [CalendarListEntry]) {
        let infos = calendars.map {
            CalendarInfo(
                id: $0.id,
                summary: $0.summary ?? $0.id,
                isPrimary: $0.primary ?? false,
                colorHex: $0.backgroundColor
            )
        }
        // F-059: the primary calendar id IS the signed-in account's e-mail — surface it for the
        // Preferences "Conectado como <email>" status line.
        let primaryEmail = calendars.first { $0.primary == true }?.id
        Task { @MainActor in
            CalendarCatalog.shared.update(infos)
            AuthStatusCenter.shared.recordConnectedEmail(primaryEmail)
        }
    }

    // MARK: - Background scheduler (NSBackgroundActivityScheduler)

    private func setupBackgroundScheduler() {
        let interval = max(preferences.syncInterval, 30)
        let sched = NSBackgroundActivityScheduler(identifier: "com.meetingalert.sync.poll")
        sched.repeats = true
        sched.interval = interval
        sched.qualityOfService = .utility
        sched.tolerance = interval * 0.1

        // F-023: invalidate any prior scheduler before swapping so re-arming (on an interval
        // change) never leaks a second armed scheduler.
        schedulerLock.lock()
        backgroundScheduler?.invalidate()
        backgroundScheduler = sched
        schedulerLock.unlock()

        sched.schedule { [weak self, sched] completion in
            guard let self, !sched.shouldDefer else {
                completion(.deferred)
                return
            }
            Task { [weak self] in
                await self?.syncNow()
                completion(.finished)
            }
        }
    }

    /// F-023: re-arm the poll scheduler with the current interval, but only if the service
    /// is already running. Before start(), the setter is a no-op — start() picks up the value.
    private func reconfigureSchedulerIfRunning() {
        schedulerLock.lock()
        let isRunning = backgroundScheduler != nil
        schedulerLock.unlock()
        guard isRunning else { return }
        setupBackgroundScheduler()
    }

    // MARK: - Wake observer

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerSync()
        }
    }

    // MARK: - Network monitor (NWPathMonitor)

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasSatisfied = self.lastNetworkStatus == .satisfied
            self.lastNetworkStatus = path.status
            if path.status == .satisfied && !wasSatisfied {
                // Network just came back — sync immediately.
                self.triggerSync()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.meetingalert.sync.network", qos: .utility))
    }
}
