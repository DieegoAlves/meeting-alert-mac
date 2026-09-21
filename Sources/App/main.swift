// OWNER: App module (composition root entry point).
//
// F-061 — "an empty window keeps appearing when I close a window."
// The app used a SwiftUI `App` whose ONLY scene was `Settings { EmptyView() }`. A SwiftUI
// scene (`Settings`, like `WindowGroup`) registers a real, framework-owned window — here an
// EMPTY one titled "Meeting Alert Settings". AppKit re-presents that scene as the app's
// fallback window whenever the process is active with no other window (e.g. right after the
// user closes Preferences/History), so a blank window kept popping back. A menu-bar
// (LSUIElement / .accessory) app must own NONE of this: it has no main window at all.
//
// FIX (root): drop the SwiftUI `App` lifecycle entirely and boot AppKit directly. With no
// SwiftUI scene there is no framework-created window, so no empty window can ever appear.
// The only windows are the ones we open by EXPLICIT action (Preferences, History) and the
// alert overlay — exactly the product rule. Views stay SwiftUI via NSHostingController; only
// the app ENTRY changed.
import AppKit

// main.swift top-level code runs on the process's initial (main) thread, i.e. the main
// actor's executor — so `assumeIsolated` is valid here and lets us call the @MainActor
// AppDelegate init + menu builder from this synchronous entry point.
@MainActor
private func bootstrap() -> AppDelegate {
    let app = NSApplication.shared
    // Menu-bar only: no Dock icon, never activates into a windowed app on its own. Mirrors
    // Info.plist LSUIElement=true; set here too so the policy holds even if launched unbundled.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    // There is no storyboard/NIB, so build the standard main menu ourselves. Without it the
    // Preferences/History windows would lose ⌘X/⌘C/⌘V/⌘A and ⌘Q — and Diego PASTES his OAuth
    // Client ID/Secret into Preferences, so a working Edit menu is mandatory. A menu-bar app
    // shows this menu only while one of its own windows is key.
    app.mainMenu = AppMenu.make()
    return delegate
}

// Global retains the delegate for the whole process lifetime (NSApplication.delegate is weak).
let appDelegate = MainActor.assumeIsolated { bootstrap() }
NSApplication.shared.run()
