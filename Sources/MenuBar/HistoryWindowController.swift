// OWNER: MenuBar module — manages the History NSWindow (singleton, reopens if already visible).
// Holds a strong reference to HistorySearchModel so search state survives view re-renders.
import AppKit
import SwiftUI
import Core

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: EventStore
    private let searchModel = HistorySearchModel()

    init(store: EventStore) {
        self.store = store
        super.init()
    }

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Histórico de Reuniões"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.contentViewController = NSHostingController(
            rootView: HistoryView(store: store, search: searchModel)
        )
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    // Release the hosting controller when the window closes to free SwiftUI resources.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}
