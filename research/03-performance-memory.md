# Performance & Memory Budget — Native macOS Menu-Bar App

> **Target**: macOS 14+ · SwiftUI/AppKit hybrid  
> **Hard targets**: < 30 MB resident (phys_footprint), ~0% CPU at idle, ONE armed timer, NO per-second loop, NO Electron

---

## 1. Memory Budget: `SwiftUI MenuBarExtra` vs `AppKit NSStatusItem` + `LSUIElement`

### Real-world footprint numbers

| Implementation | Resident (phys_footprint) | Source |
|---|---|---|
| SwiftUI `MenuBarExtra` | **~56 MB** | [A 13MB Cursor Monitor: AppKit, Zero Dependencies – DEV](https://dev.to/woojinahn/a-13mb-cursor-monitor-appkit-undocumented-apis-zero-dependencies-1k72) |
| AppKit `NSStatusItem` only | **~13 MB** | [A 13MB Cursor Monitor: AppKit, Zero Dependencies – DEV](https://dev.to/woojinahn/a-13mb-cursor-monitor-appkit-undocumented-apis-zero-dependencies-1k72) |
| Typical SwiftUI menu-bar app | 30–50 MB | [A 13MB Cursor Monitor – DEV](https://dev.to/woojinahn/a-13mb-cursor-monitor-appkit-undocumented-apis-zero-dependencies-1k72) |

SwiftUI `MenuBarExtra` allocates the full SwiftUI rendering pipeline at launch, whether or not any view is visible. That alone accounts for 40+ MB that can't be reclaimed at idle.

### Recommendation: **AppKit `NSStatusItem` + SwiftUI popover (NSHostingController bridge)**

Use `NSStatusItem` for the status bar button (pure AppKit, minimal overhead). Inject SwiftUI views only inside the popover/panel via `NSHostingController(rootView:)`, instantiated **on demand**. This matches the 13 MB profile.

```swift
// AppKit shell — no SwiftUI rendering pipeline at launch
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "⏰ 12:34"

// SwiftUI injected only when popover opens
let popover = NSPopover()
popover.contentViewController = NSHostingController(rootView: AlertMenuView())
```

### `LSUIElement` — agent app (no Dock icon)

Set in `Info.plist`:

```xml
<key>LSUIElement</key>
<true/>
```

This marks the app as a *background agent*: no Dock icon, no app switcher entry. [Apple Info.plist reference](https://developer.apple.com/documentation/bundleresources/information_property_list/lsuielement). Combined with `NSStatusItem`, the user's only touchpoint is the menu-bar icon.

**Trade-offs**:  
- `LSUIElement = true` means no `Command-Q` unless you handle it explicitly in `NSApplicationDelegate` — [Apple Developer Forums](https://developer.apple.com/forums/thread/743070).  
- Prevents App Store restrictions around background apps (no `UIBackgroundModes` equivalent needed on macOS).

---

## 2. Timer Strategy: Single `DispatchSourceTimer`, No Per-Second Loop

### Decision: ONE armed `DispatchSourceTimer`, rearmed only for the next alert

Never use a `Timer.scheduledTimer` every second for a countdown — it fires on the main RunLoop regardless of whether the menu is open, burns CPU at idle, and accumulates drift.

```swift
final class AlertScheduler {
    private var timer: DispatchSourceTimer?

    func arm(fireAt deadline: Date) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(0, deadline.timeIntervalSinceNow)
        // leeway: system can delay up to 500ms for power coalescing
        t.schedule(deadline: .now() + interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            self?.timerFired()
        }
        t.resume()
        timer = t
    }

    func disarm() {
        timer?.cancel()
        timer = nil
    }

    private func timerFired() {
        timer = nil          // fired; will be rearmed for the next alert
        AlertWindowController.show()
    }
}
```

API reference: [`DispatchSourceTimer`](https://developer.apple.com/documentation/dispatch/dispatchsourcetimer), [`schedule(deadline:leeway:)`](https://developer.apple.com/documentation/dispatch/dispatchsourcetimer/schedule(deadline:leeway:))

**`leeway`** is the GCD equivalent of `Timer.tolerance`. A larger leeway lets the kernel coalesce this timer's wakeup with nearby system wakeups, reducing CPU wakes at idle. For an alert that fires at a known calendar time, `leeway: .milliseconds(500)` is imperceptible to users.

**`Timer.tolerance`** (for `RunLoop`-based `Timer`) serves the same role:

```swift
let t = Timer(timeInterval: interval, repeats: false) { _ in ... }
t.tolerance = 0.5   // seconds
RunLoop.main.add(t, forMode: .common)
```

For a single-shot next-alert timer, `DispatchSourceTimer` is preferable because it doesn't require a live RunLoop and fires reliably on a background queue if needed.

### Refreshing the menu-bar countdown **only while menu is open**

Attach an `NSMenuDelegate` to the `NSMenu` that powers the status-item dropdown:

```swift
extension StatusMenuController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        startCountdownRefresh()   // create a 1-second display timer
    }
    func menuDidClose(_ menu: NSMenu) {
        stopCountdownRefresh()    // cancel it immediately
    }
}

private func startCountdownRefresh() {
    refreshTimer = DispatchSource.makeTimerSource(queue: .main)
    refreshTimer?.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
    refreshTimer?.setEventHandler { [weak self] in self?.updateCountdownItem() }
    refreshTimer?.resume()
}
```

At idle (menu closed), **zero timers fire**. The per-second display timer exists only during the ~seconds the user actually looks at the menu.

**Trade-off**: If the user keeps the menu open for minutes, a 1-second `DispatchSourceTimer` is still cheaper than a `Timer.scheduledTimer` on the main RunLoop because it can be dispatched on a private serial queue and marshalled to main only for UI updates.

---

## 3. Background Sync: `NSBackgroundActivityScheduler`, App Nap, Wake/Sleep

### `NSBackgroundActivityScheduler` — for calendar data refresh

Use this for any periodic sync that is *deferrable* (e.g., refreshing calendar event list every 15–60 minutes). The system automatically respects App Nap, thermal state, and battery.  
[Apple Energy Efficiency Guide — Scheduling Background Activity](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)

```swift
let sync = NSBackgroundActivityScheduler(identifier: "com.example.meeting-alert.calendar-sync")
sync.interval = 30 * 60          // every 30 minutes on average
sync.tolerance = 10 * 60         // ±10-minute window
sync.repeats = true
sync.qualityOfService = .utility  // not urgent; system may batch

sync.schedule { completion in
    Task {
        await CalendarStore.shared.refresh()
        completion(.finished)
    }
}
```

**App Nap behaviour**: `NSBackgroundActivityScheduler` internally uses the XPC Activity API. When the app is Nap-eligible (not frontmost, screen not showing the app's windows), the system may delay tasks up to the `tolerance` window. This is intentional and desired — it keeps idle CPU near zero.  
[NSBackgroundActivityScheduler — Apple Docs](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler)

**`shouldDefer` guard** — always honour it:

```swift
sync.schedule { [weak sync] completion in
    guard !(sync?.shouldDefer ?? true) else {
        return completion(.deferred)
    }
    // do the work
    completion(.finished)
}
```

### Wake/sleep notifications

Subscribe via `NSWorkspace.shared.notificationCenter` to re-arm the alert timer after sleep:

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil, queue: .main) { [weak self] _ in
        self?.scheduler.rearmForNextAlert()   // recompute next deadline
    }

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: nil, queue: .main) { [weak self] _ in
        self?.scheduler.disarm()   // avoid spurious fire on wake
    }
```

[`didWakeNotification` — Apple Docs](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification)

**Caveat**: Sleep/wake notification timing is inconsistent on certain MacBook models when unplugged. [Apple Developer Forums — Sleep State Notification Inconsistencies](https://developer.apple.com/forums/thread/796109). Always re-check the next alert deadline on wake rather than trusting that `disarm()` fired cleanly.

### `NWPathMonitor` — refresh calendar on network change

```swift
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { [weak self] path in
    guard path.status == .satisfied else { return }
    Task { await CalendarStore.shared.refresh() }
}
monitor.start(queue: DispatchQueue(label: "net.monitor"))
```

[`NWPathMonitor` — Apple Docs](https://developer.apple.com/documentation/network/nwpathmonitor)

Hold the monitor alive for the app's lifetime. On network restoration, trigger one refresh immediately instead of waiting for the next `NSBackgroundActivityScheduler` window.

---

## 4. Overlay Window Lifecycle: Create on Demand, Destroy on Dismiss

For an alert overlay (the "you have a meeting in 1 minute" banner), **never keep a window alive at idle**. An invisible NSWindow still costs ~2–4 MB of backing store.

```swift
final class AlertWindowController {
    static func show() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false  // ARC manages lifetime; see [1]
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: AlertView {
            window.close()   // dismiss callback
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        // No strong reference stored — window closes itself; ARC releases it
    }
}
```

**`isReleasedWhenClosed = false`** is required when creating an `NSWindow` programmatically under ARC. The default `true` causes a double-free crash on close because AppKit tries to `release` the window after `close()` while ARC also holds a reference. [NSWindow Memory Management — lapcatsoftware.com](https://lapcatsoftware.com/articles/working-without-a-nib-part-12.html)

**Deallocation path (macOS 10.13+)**: AppKit holds a strong reference to any ordered-in window. When `window.close()` is called, AppKit removes it from `_openWindows`, dropping the strong reference. With ARC and no other strong reference, the `NSWindow` is freed immediately. [NSWindow Memory Management — lapcatsoftware.com](https://lapcatsoftware.com/articles/working-without-a-nib-part-12.html)

**Trade-off**: Creating a new `NSWindow` per alert incurs ~5–20ms of window-server setup latency. For an alert banner that fires at most once per meeting, this is imperceptible. The idle memory savings (0 bytes vs ~2-4 MB per retained window) are worth it.

---

## 5. Measuring Footprint: Reproducible QA Method

### Primary: `footprint` command

[`footprint(1)` man page — keith.github.io](https://keith.github.io/xcode-man-pages/footprint.1.html)

`footprint` reports **phys_footprint** — the kernel ledger value for dirty + anonymous memory. This is the metric Apple uses in Xcode's memory gauge, and the one that matters for system pressure. It excludes clean file-backed pages that can be evicted freely.

```bash
# Run as root or via sudo; target by name
sudo footprint -p MeetingAlert

# Save JSON for diff/CI
sudo footprint -p MeetingAlert -j /tmp/baseline.json

# Quick one-liner: phys_footprint in MB
sudo footprint MeetingAlert | grep -i "physical footprint"
```

**Pass condition**: `phys_footprint < 30 MB` at idle (menu closed, no overlay).

### Secondary: `vmmap` — detailed region breakdown

```bash
vmmap -summary $(pgrep MeetingAlert)
```

Look for `TOTAL DIRTY` and `TOTAL SWAPPED` rows. Useful for diagnosing *what* is dirty (heap, stack, mapped files, IOKit surfaces).

### CPU: `top` idle snapshot

```bash
top -pid $(pgrep MeetingAlert) -stats pid,cpu,mem -l 3
```

Capture 3 samples after 30 seconds of idle. CPU should read `0.0` between timer fires.

### Instruments — for leak and allocation investigation

Open Xcode → Product → Profile (⌘+I) → choose **Allocations** template.

- Filter by `PERSISTENT BYTES` growth over 5 minutes of idle — it must be flat.
- Switch to **Leaks** template and run for 60 seconds — zero leaks expected.
- Look for `NSHostingView`, `NSWindow`, or `DispatchSourceTimer` objects that accumulate.

### Automated QA checklist (builder + reviewer)

| Check | Command / Method | Pass condition |
|---|---|---|
| Idle phys_footprint | `sudo footprint -p MeetingAlert` | < 30 MB |
| Idle CPU | `top -pid <pid> -l 5 -stats cpu` | 0.0% between timer fires |
| No leaks | `leaks <pid>` or Instruments Leaks | 0 leaks |
| Allocation growth | Instruments Allocations, 5-min idle | Flat persistent bytes |
| Timer count | `vmmap <pid> \| grep -i timer` | 1 armed DispatchSourceTimer at idle |
| Window count | `CGWindowListCopyWindowInfo` or Instruments | 0 windows at idle |

---

## 6. Known SwiftUI Memory-Leak Pitfalls in Menu-Bar Apps

### 6.1 `@ObservedObject` through `NSHostingController` — documented retain cycle

When you pass an `@ObservedObject` into an `NSHostingController`, the hosting controller may retain the view model even after `close()`. [Swift Forums — Memory leak with @ObservedObject through UIHostingController rootView](https://forums.swift.org/t/memory-leak-by-using-observedobject-through-uihostingcontroller-rootview/66750)

**Fix**: Prefer `@StateObject` inside the root SwiftUI view itself, or nil out `contentViewController` before closing:

```swift
window.contentViewController = nil  // breaks hosting controller's retain
window.close()
```

### 6.2 Strong closures in `DispatchSourceTimer` / `Timer`

```swift
// BAD — self captures timer, timer captures self
timer.setEventHandler { self.update() }

// GOOD
timer.setEventHandler { [weak self] in self?.update() }
```

[DEV Community — SwiftUI Memory Leaks: Where They Hide](https://dev.to/vnayak_hejib/memory-leaks-in-swiftui-where-they-hide-how-to-catch-them-real-world-examples-84i)

### 6.3 `NotificationCenter` observers not removed

`NSWorkspace.shared.notificationCenter` observers added with `addObserver(forName:object:queue:using:)` return an opaque token. Failing to `removeObserver` on that token leaks the closure.

```swift
private var wakeToken: NSObjectProtocol?

wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil, queue: .main) { [weak self] _ in self?.onWake() }

// In deinit:
deinit {
    if let t = wakeToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
}
```

### 6.4 `NSWindow` delegate retain cycle

`NSWindow` holds a **strong** reference to its `delegate`. If the delegate also holds a strong reference to the window, you have a cycle. [This Window Is Leaking — byla.lt](https://byla.lt/posts/this-window-is-leaking/)

**Fix**: Make the window's delegate a weak reference holder, or use a separate coordinator object that only holds a weak window reference.

### 6.5 `NSPopover` not released after `close()`

If `NSPopover` is created once and held alive indefinitely, its `contentViewController` (the `NSHostingController`) is also alive, keeping the entire SwiftUI view graph in memory. For a menu-bar app showing only occasional popovers, create the popover lazily and nil it on `popoverDidClose`:

```swift
func popoverDidClose(_ notification: Notification) {
    popover?.contentViewController = nil
    popover = nil
}
```

### 6.6 `@StateObject` misuse in child views

A `@StateObject` created inside a child view is owned by the view's identity, not the parent. If navigation pushes new views, each can create a fresh `@StateObject` that outlives its view. [Medium — Understanding Retain Cycles and Memory Leaks in SwiftUI](https://mahmudul-razib.medium.com/understanding-retain-cycles-and-memory-leaks-in-ios-swift-and-swiftui-11354801e0e2)

For menu-bar apps: hoist observable model objects to the app level (`@main` struct or `AppDelegate`) and pass them down as environment objects.

---

## Measurable Performance Checklist

Use this before every release candidate:

```
[ ] sudo footprint -p MeetingAlert → phys_footprint < 30 MB at idle
[ ] top -pid <pid> -l 10 → CPU 0.0% for all 10 samples at idle (menu closed)
[ ] leaks <pid> → 0 leaks after 5 min idle
[ ] Instruments Allocations: persistent bytes flat over 5 min idle
[ ] One DispatchSourceTimer in vmmap output at idle (the next-alert timer)
[ ] Zero NSWindow objects in Instruments Object Graph at idle
[ ] NSPopover + NSHostingController confirmed nil after popover close (Instruments Allocations filter "NSHostingController")
[ ] Wake/sleep cycle: disarm → wake → rearm → alert fires correctly
[ ] Network reconnect: NWPathMonitor triggers calendar refresh within 5 s
```

---

## Summary: Recommended Decisions

| Question | Decision | Key risk |
|---|---|---|
| UI framework for shell | AppKit `NSStatusItem` + `LSUIElement` | More code; use SwiftUI only inside `NSHostingController` |
| Timer | Single `DispatchSourceTimer`, rearmed per alert | Must cancel before each rearm; strong closure → leak |
| Display countdown | Per-second timer only while `NSMenu` is open (`menuWillOpen`/`menuDidClose`) | None — ideal pattern |
| Background sync | `NSBackgroundActivityScheduler` (≥10-min intervals) + `NWPathMonitor` trigger | `shouldDefer` must be honoured |
| Wake/sleep | `NSWorkspace.willSleepNotification` / `didWakeNotification` | Notification timing inconsistent on some MacBooks |
| Overlay window | Create on demand, `isReleasedWhenClosed = false`, nil after `close()` | 5–20ms window-server setup per alert |
| Measurement | `footprint -p`, `leaks`, Instruments Allocations | `footprint` requires sudo |
