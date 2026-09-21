// OWNER: Core (frozen contract — do NOT edit after scaffold).
import Foundation

public enum AlertSound: Codable, Sendable {
    case system(String)
    case file(URL)
}

// MARK: - F-064: Overlay customization (the ONE option model, read at overlay-build time)

/// Plain RGBA color (0…1 components). Core stays Foundation-only, so the UI modules convert this
/// to their own `Color`/`NSColor`. `nil` accent means "use the system accent color".
public struct RGBAColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
}

/// Foreground/text palette. `.dark` = light text (current behavior); `.light` = dark text;
/// `.automatic` = follow the system appearance, evaluated when the overlay is built.
public enum OverlayTheme: String, Codable, Sendable, CaseIterable { case light, dark, automatic }

/// Scales the WHOLE type ramp. `.medium` reproduces the current sizes.
public enum OverlayTextSize: String, Codable, Sendable, CaseIterable { case small, medium, large }

/// Fullscreen (current) vs a compact non-activating floating panel.
public enum OverlayMode: String, Codable, Sendable, CaseIterable { case fullscreen, floating }

/// Anchor for the floating panel.
public enum OverlayCorner: String, Codable, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, center
}

/// Which monitors the overlay covers. Fullscreen honors all three; the single floating panel maps
/// `.all` → primary screen (a lone window cannot span every display).
public enum OverlayMonitors: String, Codable, Sendable, CaseIterable { case all, primary, mouse }

/// Every customizable overlay option, for BOTH the real T-1 overlay and the test overlay. Defaults
/// reproduce the pre-F-064 behavior EXACTLY, so an app with no stored options looks unchanged.
public struct OverlayOptions: Codable, Sendable, Equatable {
    // GROUP 1 — Aparência
    public var backgroundColor: RGBAColor      // backdrop fill (default black)
    public var backgroundOpacity: Double       // 0.30…1.0 (default 0.82 == current)
    public var theme: OverlayTheme             // text/foreground palette (default .dark == current)
    public var textSize: OverlayTextSize       // scales the whole type ramp (default .medium)
    public var accentColor: RGBAColor?         // Entrar button; nil == system accent (default nil)
    // GROUP 2 — Conteúdo exibido (a false toggle REMOVES the view, not just hides it)
    public var showParticipants: Bool          // default true  (current)
    public var showDescription: Bool           // default false (not shown today)
    public var descriptionLineLimit: Int       // truncate at N lines (default 3)
    public var showLocation: Bool              // default false
    public var showCalendarName: Bool          // default false
    public var showCountdown: Bool             // default true  (current)
    public var showCallLink: Bool              // call URL as text (default false)
    // GROUP 3 — Modo e posição
    public var mode: OverlayMode               // default .fullscreen (current)
    public var floatingCorner: OverlayCorner   // default .topRight
    public var floatingMargin: Double          // points from the screen edge (default 24)
    public var monitors: OverlayMonitors       // default .all (current)
    public var autoCloseSeconds: Int           // 0 == never (default 0); on close treat as "Depois"
    // GROUP 4 — Som e snooze
    public var volume: Double                  // 0.0…1.0 via AVAudioPlayer.volume (default 1.0)
    public var soundRepeatSeconds: Int         // repeat every N s until interaction; 0 == once
    public var snoozeMinutes: [Int]            // exactly 3 slots (default [1, 3, 5])

    public init(
        backgroundColor: RGBAColor = .black,
        backgroundOpacity: Double = 0.82,
        theme: OverlayTheme = .dark,
        textSize: OverlayTextSize = .medium,
        accentColor: RGBAColor? = nil,
        showParticipants: Bool = true,
        showDescription: Bool = false,
        descriptionLineLimit: Int = 3,
        showLocation: Bool = false,
        showCalendarName: Bool = false,
        showCountdown: Bool = true,
        showCallLink: Bool = false,
        mode: OverlayMode = .fullscreen,
        floatingCorner: OverlayCorner = .topRight,
        floatingMargin: Double = 24,
        monitors: OverlayMonitors = .all,
        autoCloseSeconds: Int = 0,
        volume: Double = 1.0,
        soundRepeatSeconds: Int = 0,
        snoozeMinutes: [Int] = [1, 3, 5]
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.theme = theme
        self.textSize = textSize
        self.accentColor = accentColor
        self.showParticipants = showParticipants
        self.showDescription = showDescription
        self.descriptionLineLimit = descriptionLineLimit
        self.showLocation = showLocation
        self.showCalendarName = showCalendarName
        self.showCountdown = showCountdown
        self.showCallLink = showCallLink
        self.mode = mode
        self.floatingCorner = floatingCorner
        self.floatingMargin = floatingMargin
        self.monitors = monitors
        self.autoCloseSeconds = autoCloseSeconds
        self.volume = volume
        self.soundRepeatSeconds = soundRepeatSeconds
        self.snoozeMinutes = snoozeMinutes
    }

    public static var `default`: OverlayOptions { OverlayOptions() }

    /// The 3 snooze slots, always exactly 3 values, clamped to a sane 1…60 range. Missing or
    /// malformed persisted values fall back to the 1/3/5 default per slot.
    public var normalizedSnoozeMinutes: [Int] {
        let fallback = [1, 3, 5]
        return (0..<3).map { i in
            let v = i < snoozeMinutes.count ? snoozeMinutes[i] : fallback[i]
            return min(60, max(1, v))
        }
    }
}

public struct Preferences: Codable, Sendable {
    public var leadMinutes: [AlertStage: Int]    // default [.notify: 5, .overlay: 1]
    public var sound: AlertSound                  // default .system("Ping")
    // F-053: persist ONLY the DISABLED (unchecked) calendar ids. Empty == every calendar
    // enabled, so a newly-added calendar defaults ON. The primary calendar is never stored
    // here (the picker keeps it non-deselectable).
    public var disabledCalendarIDs: Set<String>
    public var syncInterval: TimeInterval         // seconds, default 60
    public var pauseUntil: Date?                   // suppress all alerts until this instant
    public var respectFocus: Bool                  // OFF via "Ignorar Focus" toggle == respect Focus
    public var overlayOptions: OverlayOptions      // F-064: overlay customization (all 4 groups)

    public init(
        leadMinutes: [AlertStage: Int],
        sound: AlertSound,
        disabledCalendarIDs: Set<String>,
        syncInterval: TimeInterval,
        pauseUntil: Date?,
        respectFocus: Bool,
        overlayOptions: OverlayOptions = .default
    ) {
        self.leadMinutes = leadMinutes
        self.sound = sound
        self.disabledCalendarIDs = disabledCalendarIDs
        self.syncInterval = syncInterval
        self.pauseUntil = pauseUntil
        self.respectFocus = respectFocus
        self.overlayOptions = overlayOptions
    }

    // Tolerant decode: an older prefs file may carry `includedCalendarIDs` (or nothing) —
    // default the new disabled-set to empty (== all enabled) rather than fail to load.
    // F-064: `overlayOptions` is likewise decodeIfPresent → defaults reproduce current behavior.
    enum CodingKeys: String, CodingKey {
        case leadMinutes, sound, disabledCalendarIDs, syncInterval, pauseUntil, respectFocus, overlayOptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leadMinutes = try c.decode([AlertStage: Int].self, forKey: .leadMinutes)
        sound = try c.decode(AlertSound.self, forKey: .sound)
        disabledCalendarIDs = try c.decodeIfPresent(Set<String>.self, forKey: .disabledCalendarIDs) ?? []
        syncInterval = try c.decode(TimeInterval.self, forKey: .syncInterval)
        pauseUntil = try c.decodeIfPresent(Date.self, forKey: .pauseUntil)
        respectFocus = try c.decode(Bool.self, forKey: .respectFocus)
        overlayOptions = try c.decodeIfPresent(OverlayOptions.self, forKey: .overlayOptions) ?? .default
    }

    public static var `default`: Preferences {
        Preferences(
            leadMinutes: [.notify: 5, .overlay: 1],
            sound: .system("Ping"),
            disabledCalendarIDs: [],
            syncInterval: 60,
            pauseUntil: nil,
            respectFocus: true,
            overlayOptions: .default
        )
    }
}
