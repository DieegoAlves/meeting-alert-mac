// OWNER: AlertUI module (Sources/AlertUI). Depends on Core ONLY.
//
// AlertPanel is the borderless, non-activating NSPanel used for the T-1min full-screen overlay.
// One instance is created per NSScreen on fire and fully destroyed on dismiss (research/03 perf:
// no retained hidden windows). It must be able to become key so it can receive keyDown events for
// the keyboard-first actions (Enter / 1-3-5 / Space / Esc); it must NOT become main —
// `canBecomeMain == true` is documented to crash a few seconds after display on some macOS
// versions (research/02 §3).
import AppKit

final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
