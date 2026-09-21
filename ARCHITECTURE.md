# ARCHITECTURE — Meeting Alert (native macOS menu-bar)

**Stack:** Swift 5.9+, AppKit shell + SwiftUI-in-`NSHostingController`, macOS 14+, **zero external dependencies**, no Google SDK. `LSUIElement = YES`. This file is the **shared contract** for 6 parallel builders. Types/protocols in `Sources/Core` are the single source of truth — **no module redefines a Core type**. Hard file ownership: no two modules edit the same file.

Grounded in `research/`: AppKit `NSStatusItem` (not `MenuBarExtra`) — 13 MB vs 56 MB [03]; OAuth PKCE S256 + loopback `127.0.0.1:<ephemeral>` + system browser, no SDK [01]; `NSPanel` at screen-saver level `1000` across all `NSScreen`/Spaces [02]; single rearmed `DispatchSourceTimer` [03]; `< 30 MB` phys_footprint idle [03].

---

## 1. MODULE MAP (`Sources/`)

- **App** — entry + lifecycle. Owns `main.swift` (pure AppKit entry: `NSApplication` + `.accessory`; F-061 replaced the old SwiftUI `MeetingAlertApp.swift`/`Settings { EmptyView() }`, whose empty scene window kept reappearing), `MainMenu.swift` (programmatic App/Edit/Window menu — the Edit menu keeps ⌘V working for pasting the OAuth secret), `AppDelegate.swift` (wires `NSStatusItem`, instantiates the concrete `GoogleAuth`, `CalendarSyncService`, `AlertScheduler`, `AlertPresenter`, `MenuBarController`, `PreferencesStore`; registers wake/sleep + `NWPathMonitor`), `Info.plist` (`LSUIElement`, notification usage), `MeetingAlert.entitlements`. Composition root only — owns no domain logic.
- **Core** — shared value types + protocols + the store. **Owns:** `CalendarEvent.swift`, `MeetingJoin.swift`, `Attendee.swift`, `EventStore.swift`, `AuthProviding.swift`, `AlertContracts.swift` (scheduler/presenter protocols + `AlertStage`, `AlertGroup`, `SnoozeInterval`), `Preferences.swift`, `CalendarCatalog.swift` (F-053: shared discovered-calendars store), `AppPaths.swift` (Application Support URLs). No AppKit UI, no network.
- **Auth** — OAuth. **Owns:** `GoogleAuth.swift` (`AuthProviding` impl), `PKCE.swift`, `LoopbackRedirectServer.swift` (`Network.framework` listener on ephemeral port + `state`/CSRF check), `KeychainStore.swift` (`SecItem*`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — legacy, kept only for one-time migration), `FileCredentialStore.swift` (F-059: refresh token + client secret in `credentials.json`, 0600, in App Support — the durable store since the ad-hoc-signed app loses Keychain access every rebuild). Depends on Core only.
- **Sync** — calendar fetch → store. **Owns:** `CalendarSyncService.swift` (poll loop + `NSBackgroundActivityScheduler`), `GoogleCalendarAPI.swift` (`events.list`, `syncToken`, 410 reset, backoff), `JoinResolver.swift` (produces `MeetingJoin`), `EventDTO.swift` (JSON decode → `CalendarEvent`). Depends on `AuthProviding` (protocol, **not** Auth files) + `EventStore`.
- **AlertUI** — the alarms. **Owns:** `AlertPresenter.swift` (`AlertPresenting` impl), `AlertPanel.swift` (`NSPanel` subclass), `AlertOverlayView.swift` (SwiftUI, countdown + key legend), `NotificationService.swift` (`UNUserNotificationCenter` category/delegate for T-5), `AlertSoundPlayer.swift` (`NSSound` stored property). Consumes Core protocols; routes user actions back to `AlertScheduling`.
- **MenuBar** — status item + lists. **Owns:** `MenuBarController.swift` (`NSStatusItem`, dynamic icon, `NSPopover` lifecycle, `NSMenuDelegate` countdown), `MenuBarView.swift` (SwiftUI: NOW / NEXT / upcoming), `HistoryWindowController.swift` + `HistoryView.swift`. Reads `EventStore` + `AlertScheduling`; opens joins.
- **Scheduler** — the brain. **Owns:** `AlertScheduler.swift` (`AlertScheduling` impl, single `DispatchSourceTimer`), `AlertPlanner.swift` (next-instant computation, overlap grouping, per-event suppression), `SnoozeState.swift`. Holds a weak `AlertPresenting`; reads `EventStore` + `Preferences`.
- **Prefs** — settings. **Owns:** `PreferencesStore.swift` (`ObservableObject`, loads/persists `Preferences` JSON), `PreferencesView.swift` (SwiftUI), `MeetingAlertFocusFilter.swift` (`SetFocusFilterIntent`). Writes `Preferences`; all others read it via `PreferencesStore`.

---

## 2. SHARED TYPE CONTRACT (`Sources/Core` — import verbatim)

```swift
// MeetingJoin.swift
public enum MeetingProvider: String, Codable, Sendable { case meet, zoom, teams, webex, other }

public struct MeetingJoin: Codable, Hashable, Sendable {
    public let provider: MeetingProvider
    public let url: URL          // canonical https URL — always safe to open
    public let deepLinkURL: URL? // native scheme (e.g. zoommtg://) only if that app is installed
    public init(provider: MeetingProvider, url: URL, deepLinkURL: URL?)
}
// Resolution rule (JoinResolver, priority order):
//  1. conferenceData.entryPoints[entryPointType=="video"].uri  → .meet
//  2. hangoutLink                                              → .meet
//  3. regex over location, then description → zoom | teams | webex (else .other if a URL found)
//  deepLinkURL: set ONLY when the native app is installed (LSCopyApplicationURLsForURL /
//  NSWorkspace.urlForApplication(toOpen:)); Zoom → zoommtg://…?confno&pwd derived from /j/<id>?pwd.
//  Otherwise deepLinkURL = nil and callers open `url` (https) via NSWorkspace.

// Attendee.swift
public enum ResponseStatus: String, Codable, Sendable { case accepted, declined, tentative, needsAction }
public struct Attendee: Codable, Hashable, Sendable {
    public let email: String
    public let displayName: String?
    public let responseStatus: ResponseStatus
    public let isSelf: Bool
    public let isOrganizer: Bool
}

// CalendarEvent.swift
public struct CalendarEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let calendarId: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [Attendee]
    public let location: String?
    public let description: String?
    public let isAllDay: Bool
    public var join: MeetingJoin?          // resolved by Sync/JoinResolver
}

// EventStore.swift — Sync WRITES, MenuBar/Scheduler READ. Window = 7 days back … end of tomorrow.
@MainActor public final class EventStore: ObservableObject {
    public static let shared: EventStore
    @Published public private(set) var events: [CalendarEvent]     // within retention window, sorted by start
    public static let didChangeNotification: Notification.Name     // posted after every mutation
    public func replaceAll(_ events: [CalendarEvent])              // full sync
    public func apply(upserts: [CalendarEvent], removedIDs: [String]) // incremental sync
    public func events(in interval: DateInterval) -> [CalendarEvent]
    public var active: [CalendarEvent] { get }    // start <= now < end
    public var upcoming: [CalendarEvent] { get }   // start > now, today+tomorrow
    public var history: [CalendarEvent] { get }    // end < now, within last 7 days
    public func load()      // from Application Support JSON at launch
    public func persist()   // debounced JSON write (Core owns AppPaths.eventStoreURL)
}

// AuthProviding.swift — Sync depends on THIS, never on Auth files.
public protocol AuthProviding: AnyObject, Sendable {
    func validAccessToken() async throws -> String  // returns fresh token, refreshing if needed
    var isAuthorized: Bool { get async }
    func signIn() async throws
    func signOut() async throws
}

// AlertContracts.swift — Scheduler-owned protocols; AlertUI/MenuBar consume.
public enum AlertStage: String, Codable, Sendable { case notify, overlay } // notify=T-5 UN, overlay=T-1 NSPanel
public enum SnoozeInterval: Int, CaseIterable, Sendable { case one = 1, three = 3, five = 5 }

public struct AlertGroup: Identifiable, Sendable {   // overlapping meetings → ONE overlay
    public let id: String
    public let events: [CalendarEvent]     // >= 1; multiple when time-overlapping
    public let stage: AlertStage
    public let fireDate: Date
}

public protocol AlertScheduling: AnyObject {
    func start()                                           // arm on launch
    func rearmForNextAlert()                               // recompute after sync/wake/prefs change
    func nextAlertInstant() -> (date: Date, stage: AlertStage, group: AlertGroup)?
    func snooze(_ group: AlertGroup, by interval: SnoozeInterval)
    func dismiss(_ group: AlertGroup)                      // "Later" / Esc
    func markAlreadyInCall(_ event: CalendarEvent)         // per-event suppression for remaining stages
    func join(_ event: CalendarEvent)                      // opens join + suppresses that event
}

public protocol AlertPresenting: AnyObject {              // AlertUI implements; Scheduler calls
    func present(_ group: AlertGroup)                      // routes to notification (T-5) or overlay (T-1)
    func presentSilentNotification(_ group: AlertGroup)    // F-052: overlay downgraded under active Focus
    func dismissActiveOverlay()
}

// Preferences.swift
public enum AlertSound: Codable, Sendable { case system(String), file(URL) }
public struct Preferences: Codable, Sendable {
    public var leadMinutes: [AlertStage: Int]   // default [.notify: 5, .overlay: 1]
    public var sound: AlertSound                 // default .system("Ping")
    public var disabledCalendarIDs: Set<String>  // F-053: empty == all enabled; stores only UNCHECKED ids
    public var syncInterval: TimeInterval        // seconds, default 60
    public var pauseUntil: Date?                 // suppress all alerts until this instant
    public var respectFocus: Bool                // F-052: false ("Ignorar Focus" ON) = fire anyway
    public static var `default`: Preferences { get }
}

// CalendarCatalog.swift (F-053) — shared like EventStore: Sync writes, Prefs reads.
public struct CalendarInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String; public let summary: String
    public let isPrimary: Bool; public let colorHex: String?   // Google backgroundColor
}
@MainActor public final class CalendarCatalog: ObservableObject {
    public static let shared: CalendarCatalog
    @Published public private(set) var calendars: [CalendarInfo]   // discovered via calendarList.list
    public func update(_ list: [CalendarInfo])
}
```

---

## 3. DATA FLOW

1. **Launch** — `AppDelegate` builds the graph; `EventStore.shared.load()`; `AlertScheduler.start()`; `MenuBarController` installs `NSStatusItem`.
2. **Auth** — `GoogleAuth.validAccessToken()`: no token → PKCE (S256) authorize in **system browser**, `LoopbackRedirectServer` on `127.0.0.1:<ephemeral>` catches `code` (validates `state`), exchanges at `oauth2.googleapis.com/token`, stores **refresh token in Keychain**. Later calls refresh silently ~60 s before `expires_in`.
3. **Sync** — `CalendarSyncService` (60 s poll + `NSBackgroundActivityScheduler`) first calls `calendarList.list` (`fields=id,summary,accessRole,primary,backgroundColor`) → publishes the account's calendars to `CalendarCatalog.shared` (feeds the Prefs picker, F-053), then `events.list` (`singleEvents=true&orderBy=startTime`, `fields` mask) **only for enabled calendars** (a calendar is enabled unless its id is in `disabledCalendarIDs`). Two lanes per calendar: windowed non-syncToken list (7 days back → end of tomorrow) used on **missing token / HTTP 410 GONE / once-per-day safety net**, and a per-calendar `syncToken` change lane (`showDeleted=true`, no time bounds) every other poll; 403/429 → exponential backoff; **HTTP 401 → `auth.invalidateAccessToken()` + retry once** (F-042).
4. **Resolve + cache** — `JoinResolver` fills `CalendarEvent.join`; **F-040: reconcile into `EventStore.apply(upserts:removedIDs:)` by event id — NEVER `replaceAll` on the sync path** (replaceAll would evict unchanged events from calendars still on the incremental lane = durable data loss). Cancelled events remove by id; calendars that did a full resync this cycle evict their own now-absent events; others keep everything → `@Published` + `didChangeNotification` + debounced JSON persist to Application Support.
5. **Plan** — on store change / wake / prefs change, `AlertScheduler.rearmForNextAlert()` → `AlertPlanner` computes the single next instant: per enabled (not in `disabledCalendarIDs`), non-all-day (F-050), non-declined, non-paused, non-suppressed event, stage times = `start − leadMinutes[stage]`; **overlapping meetings collapse into one `AlertGroup`**; earliest future instant wins.
6. **Arm** — ONE `DispatchSourceTimer` (`leeway .milliseconds(500)`, `[weak self]`) armed for that instant; disarmed on `willSleep`, rearmed on `didWake`.
7. **Fire** — `notify` stage → `AlertPresenter.present` posts a `.timeSensitive` `UNUserNotification` (Join / Snooze 1 / Snooze 5). `overlay` stage → on-demand `AlertPanel` per `NSScreen` at level `1000`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `canBecomeKey=true`/`canBecomeMain=false`; plays `AlertSound`. **F-052: if a macOS Focus/DND is active and `respectFocus` is on (default), the intrusive `overlay` stage is DOWNGRADED to a silent `.passive` notification (`presentSilentNotification`, no sound) instead of taking over the screen; the `notify` stage still delivers.** After firing, scheduler rearms for the next instant.
8. **Actions** (overlay keys / notification buttons) → `AlertScheduling`: **Return** `join(event)` (opens `deepLinkURL ?? url`), **1/3/5** `snooze(group,by:)`, **Esc** `dismiss(group)`, **Space** `markAlreadyInCall(event)`. Each destroys panels (`contentViewController=nil` then `close()`) and rearms.
9. **Browse** — MenuBar popover renders `active` (NOW, late-join), `upcoming` split into **"Próximas hoje"** and a separate **"Amanhã"** section (F-051, capped at 5) so tomorrow's meetings are visible, plus **"Já passaram hoje"**; History window renders `history`; per-second countdown timer runs **only** while the menu/popover is open (`menuWillOpen`/`menuDidClose`).

---

## 4. PERF BUDGET (from `research/03`)

- **Target:** `phys_footprint < 30 MB` at idle (menu closed, no overlay); ~0 % CPU between fires; exactly **one** armed timer; **zero** windows at idle.
- **Measure:** `footprint -p MeetingAlert` (< 30 MB phys_footprint; **no sudo needed for your own process** — F-002; RSS is NOT the budget, it counts shared COW pages); `top -pid <pid> -l 10` (0.0 %); `leaks <pid>` (0); Instruments Allocations flat over 5 min; `vmmap` shows 1 `DispatchSourceTimer`. Run `scripts/measure-footprint.sh` (exit 0=PASS, 1=FAIL, 2=UNMEASURED).
- **Tactics:** AppKit `NSStatusItem` shell, SwiftUI **only** inside on-demand `NSHostingController` (popover, overlay, prefs, history) — nil `contentViewController` before close. Overlay panels created on fire, destroyed on dismiss (`isReleasedWhenClosed=false`). Single rearmed `DispatchSourceTimer`, never a per-second run loop; countdown timer scoped to menu-open. `NSSound` stored property (no `AVAudioEngine`). All timer/observer closures `[weak self]`; wake/sleep observer tokens removed in `deinit`. `NSBackgroundActivityScheduler` (honor `shouldDefer`) + `NWPathMonitor` for deferrable sync; `LSUIElement` (handle ⌘Q explicitly).

---

## FIXED NAMES (scaffold: create verbatim)

**Core types:** `MeetingProvider`, `MeetingJoin`, `ResponseStatus`, `Attendee`, `CalendarEvent`, `EventStore` (+ `EventStore.didChangeNotification`), `AlertStage`, `SnoozeInterval`, `AlertGroup`, `AlertSound`, `Preferences`, `CalendarInfo`, `CalendarCatalog` (F-053).
**Core protocols:** `AuthProviding`, `AlertScheduling`, `AlertPresenting`.
**Concrete impls (per module):** Auth→`GoogleAuth`; Sync→`CalendarSyncService`, `GoogleCalendarAPI`, `JoinResolver`; Scheduler→`AlertScheduler`, `AlertPlanner`; AlertUI→`AlertPresenter`, `AlertPanel`, `NotificationService`, `AlertSoundPlayer`; MenuBar→`MenuBarController`, `HistoryWindowController`; Prefs→`PreferencesStore`, `MeetingAlertFocusFilter`; App→`AppDelegate`.
