# UX Research: Meeting Alert + History — Native macOS Menu-Bar App
> macOS 14+, SwiftUI + AppKit, minimalist tone  
> Researched: 2026-09-15

---

## 1. Anatomy of "In Your Face" — Lessons and Warnings

### What it does well
["In Your Face"](https://www.inyourface.app/) blocks the **entire screen** with a modal, full-screen alert the moment a meeting approaches. The core insight: subtle banner notifications are invisible to hyperfocused people. The app targets this gap directly, and its [App Store reviews](https://apps.apple.com/us/app/meeting-reminder-in-your-face/id1476964367) show a devoted ADHD/time-blindness user base ("the only thing keeping me from missing every single meeting").

Key mechanics worth copying:
| Feature | Detail |
|---|---|
| Full-screen takeover | Blocks everything, dismissal is forced — not passive |
| Calendar filtering | Filter which calendars trigger alerts; "focus time" blocks are excluded [inference] |
| 60+ conferencing services | Auto-detects links, one-click Join from the overlay |
| Multi-monitor opt-in | "You can opt to fill all of them" with the alert [Macworld](https://www.macworld.com/article/696313/in-your-face-review.html) |
| Snooze intervals | 1 min and 5 min options |
| Custom sounds | System sounds + novelty alternatives |
| Menu bar upcoming list | Shows next events with countdown and join button |

### What irritates users / to avoid
- **Multi-monitor inconsistency**: One App Store reviewer (3 screens: laptop + 2 external) noted "the warning varies in where it lands" — users expect all screens to fire simultaneously and reliably. [App Store reviews](https://apps.apple.com/us/app/meeting-reminder-in-your-face/id1476964367)
- **Fixed list view**: The calendar list dialog cannot be resized — a "small nit" that compounds when users have many calendars. [Macworld](https://www.macworld.com/article/696313/in-your-face-review.html)
- **No granular snooze on the overlay**: Only 1 or 5 min; no typed-in duration or per-event snooze. [inference from feature description]
- **Focus mode opacity**: No visible state shown in the overlay about whether DND is active or will be overridden. [inference]
- **Single dismiss path**: Requires a click; power users want keyboard-only dismissal.

### Decision
Copy: all-monitors full-screen, join link detection, snooze with keyboard shortcuts, calendar filtering.  
Avoid: fixed-size list views, implicit multi-monitor behavior, no keyboard-first dismissal.

---

## 2. Apple HIG — When Full-Screen Takeover vs. Notification

Apple's HIG recommends a graduated approach based on urgency and interruption cost. Relevant principles from [Apple HIG: Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications) (page requires login to render full content; principles below are well-documented in WWDC sessions):

| Mode | When to use |
|---|---|
| **Passive notification** (banner, no sound) | Background info that can wait |
| **Active notification** (banner + sound) | Default for time-sensitive reminders |
| **Time-sensitive notification** | Breaks through Focus; use for imminent events |
| **Critical alert** | Medical/safety; requires Apple entitlement; always overrides DND/silent |
| **Full-screen takeover** (custom window) | When the system notification mechanism is insufficient because the user is in hyperfocus and WILL miss a system banner. Meeting alerts exactly qualify — the app *is* the exception, not an abuse. |

**Guidance for our app:**  
The T‑5min stage should use `UNUserNotificationCenter` (respects system preferences, shows in NC). The T‑1min stage is where the full-screen custom overlay becomes justified — at that point, missing the meeting is the worst outcome. Present the overlay AND deliver a time-sensitive `UNUserNotification` as a fallback (in case the overlay is missed on a monitor the user isn't looking at).

---

## 3. T−1 min Full-Screen Overlay in AppKit

### Window level selection

From [NSWindowLevel deep dive — Noticky](https://www.noticky.app/en/blog/macos-window-levels-explained) and [Jim Fisher's level reference](https://jameshfisher.com/2020/08/03/what-is-the-order-of-nswindow-levels/):

| Constant | Value | Notes |
|---|---|---|
| `NSNormalWindowLevel` | 0 | Regular app windows |
| `NSFloatingWindowLevel` | 3 | Floaters / palettes |
| `NSModalPanelWindowLevel` | 8 | Modal dialogs |
| `NSMainMenuWindowLevel` | 24 | The menu bar |
| `NSStatusWindowLevel` | 25 | Status bar overlays |
| `NSPopUpMenuWindowLevel` | 101 | Context menus |
| `NSOverlayWindowLevel` | 102 | Overlays (macOS private alias) |
| `NSScreenSaverWindowLevel` | 1000 | Screen savers |

**Recommended level:** `NSWindow.Level(rawValue: 1000)` (screen saver level) is the highest public level that reliably appears above all normal app content. For the alert overlay, this is the right choice.

### The full-screen app challenge

This is the hardest part. A window's level controls stacking *within* a Space. Fullscreen apps create their own Space. To cross that boundary you need **both**:

1. An elevated level (≥ floating)
2. The right `collectionBehavior`

From [Apple Developer Forums: Window visible on all spaces](https://developer.apple.com/forums/thread/26677) and [Make NSWindow show up on every workspace](https://developer.apple.com/forums/thread/671674):

```swift
// Use NSPanel, not NSWindow, for cross-space overlays
let alertPanel = NSPanel(
    contentRect: screen.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
alertPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindowLevelKey)))
alertPanel.collectionBehavior = [
    .canJoinAllSpaces,       // appear on every existing Space
    .fullScreenAuxiliary,    // allowed to coexist with fullscreen app's Space
    .stationary              // don't participate in Exposé/Mission Control
]
alertPanel.isOpaque = false
alertPanel.backgroundColor = .clear
```

> **⚠️ Trade-off:** `.fullScreenAuxiliary` lets the window *enter* the fullscreen Space but does NOT guarantee it renders *above* the fullscreen app's content. In practice, screen-saver level combined with `.canJoinAllSpaces` and `.fullScreenAuxiliary` works for most apps. Apps using Metal/full-screen exclusive mode (games) may still occlude. [Apple Developer Forums thread 759780](https://developer.apple.com/forums/thread/759780) documents this unresolved limitation.

### One window per NSScreen (all monitors)

```swift
var alertPanels: [NSPanel] = []

func showAlertOnAllScreens() {
    NSScreen.screens.forEach { screen in
        let panel = makeAlertPanel(frame: screen.frame)
        panel.setFrameOrigin(screen.frame.origin)
        panel.makeKeyAndOrderFront(nil)
        alertPanels.append(panel)
    }
}
```

Hold strong references in a controller; ARC will deallocate panels otherwise.

### Keyboard capture

`NSPanel` with `.borderless` + `.nonactivatingPanel` does NOT become key by default. Override to capture keyboard events:

```swift
class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }  // must be false — crashes if true on some macOS versions
}
```

> **⚠️ Risk:** `canBecomeMain: true` is documented to crash 3 seconds after display on some macOS versions. Always keep `canBecomeMain: false`. [SwiftUI/macOS full-screen overlay discussion](https://levelup.gitconnected.com/swiftui-macos-full-screen-cover-overlay-7a5bd886d795)

### Keyboard shortcuts in the overlay

```swift
// In the NSPanel's keyDown(_ event: NSEvent) or via NSEvent.addLocalMonitorForEvents
switch event.keyCode {
case 36, 76:   // Return, KP Enter → Join
    joinMeeting()
case 18:        // "1" → snooze 1 min
    snooze(minutes: 1)
case 20:        // "3" → snooze 3 min
    snooze(minutes: 3)
case 23:        // "5" → snooze 5 min
    snooze(minutes: 5)
case 49:        // Space → "already in the call"
    markAlreadyJoined()
case 53:        // Esc → dismiss (Later)
    dismiss()
default: break
}
```

Display a key legend in the overlay UI (small, bottom-aligned monospace, low opacity).

### Live countdown + sound

Show a countdown label (`Timer.publish(every: 1, on: .main, in: .common).autoconnect()` in SwiftUI). Play sound when the overlay appears (see §6).

### Handling newly created Spaces

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    self,
    selector: #selector(spaceChanged),
    name: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil
)

@objc func spaceChanged() {
    alertPanels.forEach { $0.makeKeyAndOrderFront(nil) }
}
```
[Apple Developer Forums: Make NSWindow show up on every workspace](https://developer.apple.com/forums/thread/671674)

---

## 4. T−5 min Discreet Stage — UNUserNotificationCenter with Actions

```swift
import UserNotifications

// 1. Define actions
let joinAction = UNNotificationAction(
    identifier: "JOIN",
    title: "Join",
    options: .foreground  // brings app to front
)
let snooze1Action = UNNotificationAction(identifier: "SNOOZE_1", title: "Snooze 1 min", options: [])
let snooze5Action = UNNotificationAction(identifier: "SNOOZE_5", title: "Snooze 5 min", options: [])

// 2. Register category (do this at app startup)
let category = UNNotificationCategory(
    identifier: "MEETING_ALERT",
    actions: [joinAction, snooze1Action, snooze5Action],
    intentIdentifiers: [],
    options: []
)
UNUserNotificationCenter.current().setNotificationCategories([category])

// 3. Schedule at T-5min
let content = UNMutableNotificationContent()
content.title = "Starting in 5 minutes"
content.body = eventTitle
content.sound = .default
content.categoryIdentifier = "MEETING_ALERT"
content.interruptionLevel = .timeSensitive  // breaks through Focus DND
// content.userInfo = ["meetingURL": url, "eventID": id]

let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilMinus5, repeats: false)
let request = UNNotificationRequest(identifier: "meeting-\(eventID)", content: content, trigger: trigger)
UNUserNotificationCenter.current().add(request)

// 4. Handle response
func userNotificationCenter(_ center: UNUserNotificationCenter,
                             didReceive response: UNNotificationResponse,
                             withCompletionHandler completionHandler: @escaping () -> Void) {
    switch response.actionIdentifier {
    case "JOIN":
        openMeetingURL(from: response.notification.request.content.userInfo)
    case "SNOOZE_1":
        rescheduleAlert(offset: 60, from: response)
    case "SNOOZE_5":
        rescheduleAlert(offset: 300, from: response)
    default:
        break
    }
    completionHandler()
}
```

**Sources:** [Hacking with Swift — acting on responses](https://www.hackingwithswift.com/read/21/3/acting-on-responses), [Cocoacasts — Actionable Notifications](https://cocoacasts.com/actionable-notifications-with-the-user-notifications-framework), [Mastering Swift Local Notifications](https://vikramios.medium.com/mastering-swift-local-notifications-a-developers-guide-f56b77ab64cc)

**Trade-offs:**
- `.timeSensitive` interruption level is the sweet spot: breaks through Focus without requiring Apple's Critical entitlement.
- macOS shows notification banners (or alerts if user sets it in System Settings > Notifications). We cannot force alert-style from code.
- macOS notification actions appear when the user long-presses or expands the notification. They are less discoverable than iOS; don't rely on them as primary UX.

---

## 5. Respecting Focus / Do Not Disturb

### What IS detectable on macOS 14+

The **Focus Filter API** (`SetFocusFilterIntent` / `AppIntents` framework, introduced macOS 13) lets apps:
- Let the **user** configure app behavior per Focus mode in System Settings > Focus
- Receive a `perform()` callback when the user's active Focus changes to one they've configured
- Query current parameters via `ExampleFocusFilter.current`

```swift
import AppIntents

struct MeetingAlertFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Meeting Alert behavior"
    
    @Parameter(title: "Suppress alerts during Focus", default: false)
    var suppressOverlay: Bool
    
    func perform() async throws -> some IntentResult {
        AppState.shared.suppressFullScreenOverlay = suppressOverlay
        return .result()
    }
}
```

**Source:** [WWDC22 — Meet Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121/), [Showing Relevant Data Using Focus Filters — Crunchy Bagel](https://crunchybagel.com/showing-relevant-data-using-focus-filters/)

### What is NOT detectable

- **Which Focus mode is active** — apps never receive the Focus mode name. If the user sets identical filter values for Work and Personal Focus, the app cannot distinguish them. [WWDC22 — Meet Focus filters](https://developer.apple.com/videos/play/wwdc2022/10121/)
- **Whether ANY Focus is active at all** without user configuration — there is no public `CNFocusStatus` or equivalent API for third-party apps. [Apple Developer Forums thread 729475](https://developer.apple.com/forums/thread/729475)
- **Focus transitions in the background** without an App Intents extension (required since the main app process may be suspended).

### Recommended approach

1. Implement `SetFocusFilterIntent` with a `suppressOverlay: Bool` parameter.
2. In System Settings, this appears under Focus > [FocusName] > Add Filter > Your App.
3. Respect this flag in your overlay scheduler.
4. Use `.timeSensitive` on the T-5min notification — this is the only mechanism that reliably pierces Focus without user opt-out.
5. **Do NOT** try to bypass Focus via private APIs or XPC hacks. App Store and notarization risk is not worth it; the T-1min overlay itself is the "last resort" path.

**Risk:** Users who enable DND and do not configure a Focus Filter will see the T-5min banner if their Focus allows Time Sensitive, but the T-1min overlay will still fire (it's a custom window, not a system notification). This is acceptable behavior for a meeting alert app.

---

## 6. Playing a Sound — NSSound vs AVAudioPlayer

### Comparison

| | `NSSound` | `AVAudioPlayer` |
|---|---|---|
| Simplicity | High — one call | Medium — setup + reference retention |
| Reference retention | Handled internally | **Must be a stored property** — local vars get ARC'd immediately, audio stops |
| Audio engine overhead | None | None (AVAudioPlayer, not AVAudioEngine) |
| Volume control | Limited | Fine-grained |
| Format support | AIFF, WAV, MP3, AAC | Same |
| Thread | Main thread | Main thread |
| Loop support | Yes | Yes |
| Best for | One-shot alert sounds | Complex playback needs |

**Source:** [Hacking with Swift — AVAudioPlayer](https://www.hackingwithswift.com/example-code/media/how-to-play-sounds-using-avaudioplayer), [Advanced Swift — Play a Sound](https://www.advancedswift.com/play-a-sound-in-swift/), [Apple Forums — AVAudioPlayer stops immediately](https://developer.apple.com/forums/thread/92672)

### Recommendation: NSSound for one-shot alert

```swift
// Load once at startup, keep as a strong property in your alert controller
final class AlertSoundPlayer {
    private var sound: NSSound?
    
    func prepare(named name: String) {
        sound = NSSound(named: name) ?? NSSound(contentsOfFile: Bundle.main.path(forResource: name, ofType: "aiff")!, byReference: false)
    }
    
    func play() {
        sound?.stop()   // reset if already playing
        sound?.play()
    }
}
```

Or the simplest possible:

```swift
NSSound(named: "Ping")?.play()   // system named sounds; main thread only
```

**Why not AVAudioEngine?** The question asks specifically about avoiding an idle audio engine. `NSSound` and `AVAudioPlayer` both use Core Audio internally but do not require an `AVAudioEngine` instance to stay alive. An `AVAudioEngine` (the explicit graph-based engine) is overkill and does hold resources at idle. Avoid it.

**Risk:** `NSSound` volume is tied to system volume; AVAudioPlayer lets you set a relative volume. If users want per-app alert volume, add an `AVAudioPlayer` with a stored property.

---

## 7. Menu-Bar List of Upcoming / Already-Started + History Window

### Architecture

Use the standard macOS menu-bar pattern ([macOS Menu Bar Guide 2026 — TechConcepts](https://techconcepts.org/blog/macos-menu-bar-guide), [Building macOS Menu Bar Apps — TechConcepts](https://techconcepts.org/blog/macos-menu-bar-swiftui-nspopover)):

```swift
@main
struct MeetingAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "video.circle", accessibilityDescription: nil)
        statusItem.button?.action = #selector(togglePopover)
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
    }
    
    @objc func togglePopover() { /* show/hide popover */ }
}
```

**Info.plist:** set `LSUIElement = YES` to suppress the Dock icon.

### Menu bar icon states

Update `statusItem.button?.image` dynamically:
- Idle: calendar icon
- ≤15 min to next meeting: clock icon with badge
- ≤1 min: red/urgent icon
- In meeting: filled circle or "live" indicator

### Popover content: Upcoming + Active

```
┌─────────────────────────────────────────┐
│  NOW (2 min ago)                    Join │
│  Design Sync · zoom.us                  │
├─────────────────────────────────────────┤
│  NEXT · in 12 min                       │
│  1:1 with Alice · meet.google.com  Join │
├─────────────────────────────────────────┤
│  IN 1h 23m                              │
│  Sprint Review · teams.microsoft.com    │
├─────────────────────────────────────────┤
│  [History]              [Settings]      │
└─────────────────────────────────────────┘
```

Sections:
1. **Already started** (started ≤ N minutes ago, still joinable) — top, highlighted, always-visible Join button with late-join link
2. **Upcoming** — sorted by time, countdown
3. **Footer**: History button + Settings gear

### History window

Use a separate `NSWindow` (not a popover) for persistence and resizability:

```swift
func openHistoryWindow() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Meeting History"
    window.center()
    window.contentViewController = NSHostingController(rootView: HistoryView())
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

History view columns: date/time | event title | duration | attended (yes/late/missed) | late-join link (if still valid).

### Late-join links

Store the meeting URL in `UserDefaults` or a lightweight SQLite/JSON store per event. Validity: calendar providers typically keep join URLs valid for the duration + some grace period. Show a "Link may be expired" label for events older than 4 hours. [inference]

---

## Summary Decisions

| Sub-question | Recommendation | Key Risk |
|---|---|---|
| In Your Face lessons | Copy: all-screen overlay, keyboard shortcuts, calendar filter. Avoid: fixed UI size, inconsistent multi-monitor, no keyboard dismissal | Multi-monitor consistency is the #1 user complaint |
| HIG alert vs notification | T-5min → `UNUserNotification` (timeSensitive). T-1min → custom full-screen overlay. Both fire to cover all attention states | Full-screen at T-5min would be too aggressive per HIG |
| Full-screen overlay AppKit | `NSPanel`, `.screenSaverWindowLevel` (1000), `.canJoinAllSpaces` + `.fullScreenAuxiliary`, one panel per `NSScreen.screens`, `canBecomeKey: true`, `canBecomeMain: false` | Exclusive-mode fullscreen apps (games) may still occlude. No perfect public API solution. |
| T-5min notification | `UNNotificationAction` + `UNNotificationCategory`, `.timeSensitive` level, actions: Join, Snooze 1min, Snooze 5min | macOS notification actions are less discoverable than iOS |
| Focus / DND | Implement `SetFocusFilterIntent` for user-configurable behavior. Cannot detect which Focus is active. Use `.timeSensitive` on notifications. Do not bypass DND programmatically | Users who don't configure Focus Filter will always get the T-1min overlay |
| Sound | `NSSound(named:)` stored as a property. No engine overhead. | Volume tied to system volume |
| Menu bar UI | `NSStatusItem` + `NSPopover` for upcoming list, separate `NSWindow` for history, dynamic icon state | `LSUIElement` must be set; SwiftUI popover needs `NSHostingController` bridge |
