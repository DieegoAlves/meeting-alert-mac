// OWNER: AlertUI module (Sources/AlertUI). Depends on Core ONLY.
//
// AlertOverlayView is the SwiftUI content of the T-1min "In Your Face" overlay: a darkened
// backdrop, the LARGE meeting title(s), start time, a LIVE countdown, the participant list, and
// the keyboard-action legend (research/02 §3). Overlapping meetings render together in a SINGLE
// overlay — this view walks `AlertGroup.events`.
//
// F-064: every visual/content/mode choice comes from `AlertOverlayModel.options` (a Core
// `OverlayOptions`), read when the overlay is built. Defaults reproduce the pre-F-064 look exactly.
// The SAME view drives the real overlay AND the test overlay AND both modes (fullscreen/floating).
//
// AlertOverlayModel drives it: ONE per overlay presentation, shared by every screen's panel, so a
// single per-second timer feeds all monitors (not one timer per screen). The presenter starts the
// model on fire and stops it on teardown. User actions are surfaced as closures the presenter wires
// to `AlertScheduling`.
import SwiftUI
import Combine
import AppKit
import Core

@MainActor
final class AlertOverlayModel: ObservableObject {
    let group: AlertGroup

    /// F-064: current overlay options. `@Published` so a live re-apply (options changed while the
    /// test overlay is up) re-renders the content instantly without relaunching the overlay.
    @Published var options: OverlayOptions

    /// Advanced once per second to refresh the live countdown; observed by every panel's view.
    @Published var now: Date = Date()

    // Action hooks — the presenter routes these to the Scheduler.
    var onJoin: (CalendarEvent) -> Void = { _ in }
    var onSnooze: (SnoozeInterval) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onAlreadyInCall: (CalendarEvent) -> Void = { _ in }

    private var timer: Timer?

    init(group: AlertGroup, options: OverlayOptions) {
        self.group = group
        self.options = options
    }

    /// Primary (earliest-starting) event — the target of the Enter / Space keyboard shortcuts.
    var primaryEvent: CalendarEvent {
        group.events.min(by: { $0.start < $1.start }) ?? group.events[0]
    }

    /// The soonest start across grouped meetings — what the header countdown counts down to.
    var earliestStart: Date {
        group.events.map(\.start).min() ?? group.fireDate
    }

    func start() {
        now = Date()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop, so we are already on the main actor.
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct AlertOverlayView: View {
    @ObservedObject var model: AlertOverlayModel
    @Environment(\.colorScheme) private var systemColorScheme

    private var options: OverlayOptions { model.options }
    private var remaining: TimeInterval { model.earliestStart.timeIntervalSince(model.now) }
    private var compact: Bool { options.mode == .floating }

    var body: some View {
        Group {
            if compact {
                content
                    .padding(scaled(20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(backdrop)
            } else {
                ZStack {
                    backdrop.ignoresSafeArea()
                    content.padding(48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.colorScheme, effectiveColorScheme)
    }

    private var backdrop: some View {
        Color(rgba: options.backgroundColor).opacity(options.backgroundOpacity)
    }

    private var content: some View {
        VStack(spacing: scaled(compact ? 12 : 28)) {
            if options.showCountdown { countdownHeader }

            VStack(spacing: scaled(compact ? 10 : 20)) {
                ForEach(model.group.events) { event in
                    eventCard(event)
                }
            }
            .frame(maxWidth: compact ? .infinity : 720)

            keyLegend
        }
    }

    // MARK: - Header

    private var countdownHeader: some View {
        VStack(spacing: scaled(6)) {
            Text(remaining > 0 ? "Começa em" : "Começou")
                .font(.system(size: fs(compact ? 13 : 22), weight: .medium))
                .foregroundStyle(secondaryColor)
            Text(Self.countdownString(remaining))
                .font(.system(size: fs(compact ? 40 : 96), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remaining <= 60 ? Color.red : primaryColor)
        }
    }

    // MARK: - Event card

    @ViewBuilder
    private func eventCard(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: scaled(compact ? 6 : 12)) {
            Text(event.title)
                .font(.system(size: fs(compact ? 20 : 44), weight: .bold))
                .foregroundStyle(primaryColor)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            HStack(spacing: scaled(10)) {
                Image(systemName: "clock")
                Text("\(Self.timeString(event.start)) – \(Self.timeString(event.end))")
                if let join = event.join {
                    Text("· \(providerLabel(join.provider))")
                }
            }
            .font(.system(size: fs(compact ? 13 : 20), weight: .medium))
            .foregroundStyle(secondaryColor)

            // GROUP 2 — each block appears only when its toggle is ON (the view is REMOVED otherwise).
            if options.showCalendarName, let cal = Self.calendarInfo(for: event.calendarId) {
                HStack(spacing: scaled(6)) {
                    Circle().fill(Self.color(forHex: cal.colorHex))
                        .frame(width: scaled(10), height: scaled(10))
                    Text(cal.summary).lineLimit(1)
                }
                .font(.system(size: fs(compact ? 12 : 16)))
                .foregroundStyle(secondaryColor)
            }

            if options.showLocation, let loc = event.location, !loc.isEmpty {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.system(size: fs(compact ? 12 : 16)))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

            if options.showParticipants {
                participantsRow(event)
            }

            if options.showDescription, let desc = event.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: fs(compact ? 12 : 16)))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(max(1, options.descriptionLineLimit))
            }

            if options.showCallLink, let url = event.join?.url {
                Text(url.absoluteString)
                    .font(.system(size: fs(compact ? 11 : 15), design: .monospaced))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: scaled(12)) {
                Button("Entrar") { model.onJoin(event) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(event.join == nil)
                    .tint(accentColor)
                Button("Já estou na call") { model.onAlreadyInCall(event) }
            }
            .controlSize(compact ? .regular : .large)
            .padding(.top, scaled(4))
        }
        .padding(scaled(compact ? 14 : 24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: scaled(compact ? 12 : 18)))
    }

    // GROUP 2 — participants with count + initials avatars.
    @ViewBuilder
    private func participantsRow(_ event: CalendarEvent) -> some View {
        let people = event.attendees
        if !people.isEmpty {
            HStack(spacing: scaled(6)) {
                let shown = Array(people.prefix(compact ? 3 : 5))
                ForEach(Array(shown.enumerated()), id: \.offset) { _, person in
                    Text(Self.initials(for: person))
                        .font(.system(size: fs(compact ? 9 : 12), weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .frame(width: scaled(compact ? 20 : 28), height: scaled(compact ? 20 : 28))
                        .background(Circle().fill(primaryColor.opacity(0.18)))
                }
                if people.count > shown.count {
                    Text("+\(people.count - shown.count)")
                        .font(.system(size: fs(compact ? 10 : 13), weight: .medium))
                        .foregroundStyle(secondaryColor)
                }
                Text("\(people.count) participante\(people.count == 1 ? "" : "s")")
                    .font(.system(size: fs(compact ? 10 : 14)))
                    .foregroundStyle(secondaryColor)
                    .padding(.leading, scaled(4))
            }
        }
    }

    // MARK: - Key legend

    private var keyLegend: some View {
        let m = options.normalizedSnoozeMinutes
        return HStack(spacing: scaled(compact ? 12 : 22)) {
            legendItem("↩", "Entrar")
            legendItem("\(m[0]) / \(m[1]) / \(m[2])", "Adiar min")
            legendItem("␣", "Já na call")
            legendItem("esc", "Depois")
        }
        .font(.system(size: fs(compact ? 10 : 14), design: .monospaced))
        .foregroundStyle(secondaryColor.opacity(0.85))
        .padding(.top, scaled(8))
    }

    private func legendItem(_ key: String, _ label: String) -> some View {
        HStack(spacing: scaled(6)) {
            Text(key)
                .padding(.horizontal, scaled(8)).padding(.vertical, scaled(3))
                .background(primaryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: scaled(6)))
            Text(label)
        }
    }

    // MARK: - Palette (GROUP 1: theme + colors + text size)

    private var effectiveColorScheme: ColorScheme {
        switch options.theme {
        case .light: return .light
        case .dark:  return .dark
        case .automatic: return systemColorScheme
        }
    }

    /// dark theme ⇒ light text (current); light theme ⇒ dark text; automatic follows the system.
    private var isLightText: Bool { effectiveColorScheme == .dark }

    private var primaryColor: Color { isLightText ? .white : .black }
    private var secondaryColor: Color { (isLightText ? Color.white : Color.black).opacity(0.72) }
    private var cardFill: Color { (isLightText ? Color.white : Color.black).opacity(0.08) }

    private var accentColor: Color? {
        options.accentColor.map { Color(rgba: $0) }   // nil ⇒ system accent (no tint override)
    }

    // MARK: - Sizing helpers (text-size ramp)

    private var textScale: CGFloat {
        switch options.textSize {
        case .small:  return 0.85
        case .medium: return 1.0
        case .large:  return 1.2
        }
    }
    /// Scale a layout constant (padding/spacing) by the type ramp.
    private func scaled(_ v: CGFloat) -> CGFloat { v * textScale }
    /// Scale a font size by the type ramp.
    private func fs(_ base: CGFloat) -> CGFloat { base * textScale }

    // MARK: - Formatting helpers

    private static func initials(for a: Attendee) -> String {
        let source = (a.displayName?.isEmpty == false ? a.displayName! : a.email)
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        let letters = parts.prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }

    private static func calendarInfo(for calendarId: String) -> CalendarInfo? {
        CalendarCatalog.shared.calendars.first { $0.id == calendarId }
    }

    /// Parse a Google `backgroundColor` hex ("#rrggbb") into a swatch color (neutral gray fallback).
    static func color(forHex hex: String?) -> Color {
        guard var s = hex else { return .gray }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return .gray }
        return Color(
            .sRGB,
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue:  Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }

    private func providerLabel(_ provider: MeetingProvider) -> String {
        switch provider {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case .webex: return "Webex"
        case .other: return "Reunião"
        }
    }

    private static func countdownString(_ interval: TimeInterval) -> String {
        let total = Int(abs(interval).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
}

// MARK: - RGBAColor → SwiftUI Color (Core stays Foundation-only; the conversion lives in AlertUI)

extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
