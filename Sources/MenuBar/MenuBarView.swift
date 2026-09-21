// OWNER: MenuBar module — SwiftUI popover content (NOW / PRÓXIMAS / JÁ PASSARAM + actions).
// Uses @ObservedObject (Combine) instead of @State — @State's SwiftUIMacros plugin is absent
// in the SPM command-line toolchain. MenuBarController starts/stops the clock via
// NSPopoverDelegate so the timer only runs while the popover is visible.
import SwiftUI
import AppKit
import Core

// Per-second clock fed by MenuBarController (NSPopoverDelegate) — no @State macro needed.
final class MenuBarClock: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            self?.now = t.fireDate
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct MenuBarView: View {
    @ObservedObject var store: EventStore
    @ObservedObject var clock: MenuBarClock
    @ObservedObject var syncStatus: SyncStatusCenter   // F-057: last-sync info for the empty state
    let scheduler: AlertScheduling
    let openHistory: () -> Void
    let postPause: () -> Void
    let postPreferences: () -> Void
    let postConnectGoogle: () -> Void
    let postTestAlert: () -> Void

    // All remaining events today.
    private var upcomingToday: [CalendarEvent] {
        let endOfToday = Calendar.current.startOfDay(for: clock.now).addingTimeInterval(86400)
        return store.upcoming.filter { $0.start < endOfToday }
    }

    // Tomorrow's events, capped at 5 to keep the menu light.
    private var upcomingTomorrow: [CalendarEvent] {
        let endOfToday = Calendar.current.startOfDay(for: clock.now).addingTimeInterval(86400)
        return Array(store.upcoming.filter { $0.start >= endOfToday }.prefix(5))
    }

    // Events that started today and are already over (in history window).
    private var pastToday: [CalendarEvent] {
        let startOfToday = Calendar.current.startOfDay(for: clock.now)
        let endOfToday = startOfToday.addingTimeInterval(86400)
        return store.history
            .filter { $0.start >= startOfToday && $0.start < endOfToday }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // NOW — active meetings
                    if !store.active.isEmpty {
                        sectionHeader("Em Reunião")
                        ForEach(store.active) { event in
                            EventRow(event: event, sublabel: "Agora") {
                                scheduler.join(event)
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    // PRÓXIMAS HOJE
                    if !upcomingToday.isEmpty {
                        sectionHeader("Próximas hoje")
                        ForEach(upcomingToday) { event in
                            EventRow(event: event, sublabel: countdown(to: event.start)) {
                                scheduler.join(event)
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    // AMANHÃ (up to 5 events)
                    if !upcomingTomorrow.isEmpty {
                        sectionHeader("Amanhã")
                        ForEach(upcomingTomorrow) { event in
                            EventRow(event: event, sublabel: countdown(to: event.start)) {
                                scheduler.join(event)
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    // JÁ PASSARAM HOJE
                    if !pastToday.isEmpty {
                        sectionHeader("Já passaram hoje")
                        ForEach(pastToday) { event in
                            EventRow(event: event, sublabel: agoString(from: event.start)) {
                                if let url = event.join?.deepLinkURL ?? event.join?.url {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    // Empty state — F-057: explicit, never an ambiguous blank menu. Distinguishes
                    // "synced fine, genuinely no events" from "sync failed" (shows the exact error).
                    if store.active.isEmpty && upcomingToday.isEmpty && upcomingTomorrow.isEmpty && pastToday.isEmpty {
                        VStack(spacing: 6) {
                            if let err = syncStatus.snapshot.lastError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Sincronização falhou")
                                    .font(.callout.bold())
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Text("Abra Preferências para detalhes.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Nenhum evento até amanhã")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                                Text(lastSyncLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 24)
                    }
                }
            }
            .frame(height: 300)

            Divider()

            // Action buttons
            VStack(spacing: 0) {
                actionButton("Conectar Google", systemImage: "person.crop.circle.badge.checkmark", action: postConnectGoogle)
                Divider().padding(.horizontal, 12)
                actionButton("Testar alerta…", systemImage: "bell.badge", action: postTestAlert)
                Divider().padding(.horizontal, 12)
                actionButton("Pausar alertas por 1h", systemImage: "pause.circle", action: postPause)
                Divider().padding(.horizontal, 12)
                actionButton("Histórico (últimos 7 dias)", systemImage: "clock.arrow.circlepath", action: openHistory)
                Divider().padding(.horizontal, 12)
                actionButton("Preferências…", systemImage: "gearshape", action: postPreferences)
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func countdown(to date: Date) -> String {
        let diff = date.timeIntervalSince(clock.now)
        guard diff > 0 else { return "agora" }
        if diff < 60 { return "em \(Int(diff))s" }
        if diff < 3600 { return "em \(Int(diff / 60))m" }
        let h = Int(diff / 3600)
        let m = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        return m > 0 ? "em \(h)h \(m)m" : "em \(h)h"
    }

    /// "última sync há X min" (or "nunca sincronizado"). F-057.
    private var lastSyncLine: String {
        guard let last = syncStatus.snapshot.lastSuccess else { return "ainda não sincronizado" }
        let diff = clock.now.timeIntervalSince(last)
        if diff < 60 { return "última sync há menos de 1 min" }
        if diff < 3600 { return "última sync há \(Int(diff / 60)) min" }
        let h = Int(diff / 3600)
        return h == 1 ? "última sync há 1h" : "última sync há \(h)h"
    }

    private func agoString(from date: Date) -> String {
        let diff = clock.now.timeIntervalSince(date)
        if diff < 60 { return "há menos de 1 min" }
        if diff < 3600 { return "há \(Int(diff / 60)) min" }
        let h = Int(diff / 3600)
        return h == 1 ? "há 1h" : "há \(h)h"
    }
}

// MARK: - EventRow

private struct EventRow: View {
    let event: CalendarEvent
    let sublabel: String
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(sublabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if event.join != nil {
                Button("Entrar", action: onJoin)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
