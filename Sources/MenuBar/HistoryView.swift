// OWNER: MenuBar module — SwiftUI history view (last 7 days) inside HistoryWindowController.
// Uses @ObservedObject (Combine) for search state — @State's SwiftUIMacros plugin is absent
// in the SPM command-line toolchain.
import SwiftUI
import AppKit
import Core

// Search state owned by HistoryWindowController so it survives view re-renders.
final class HistorySearchModel: ObservableObject {
    @Published var text = ""
}

struct HistoryView: View {
    @ObservedObject var store: EventStore
    @ObservedObject var search: HistorySearchModel

    private var filtered: [CalendarEvent] {
        guard !search.text.isEmpty else { return store.history }
        return store.history.filter {
            $0.title.localizedCaseInsensitiveContains(search.text)
        }
    }

    // Days sorted most-recent first; each day's events sorted most-recent first.
    private var groupedByDay: [(Date, [CalendarEvent])] {
        let cal = Calendar.current
        var map: [Date: [CalendarEvent]] = [:]
        for event in filtered {
            let day = cal.startOfDay(for: event.start)
            map[day, default: []].append(event)
        }
        return map.keys
            .sorted(by: >)
            .map { day in (day, map[day]!.sorted { $0.start > $1.start }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar reunião…", text: $search.text)
                    .textFieldStyle(.plain)
                if !search.text.isEmpty {
                    Button {
                        search.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    search.text.isEmpty ? "Nenhuma reunião" : "Sem resultados",
                    systemImage: "calendar",
                    description: Text(
                        search.text.isEmpty
                        ? "Nenhuma reunião nos últimos 7 dias."
                        : "Tente outro termo de busca."
                    )
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, events in
                        Section {
                            ForEach(events) { event in
                                HistoryEventRow(event: event)
                            }
                        } header: {
                            Text(dayLabel(day))
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Hoje" }
        if cal.isDateInYesterday(day) { return "Ontem" }
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .none
        return fmt.string(from: day).capitalized
    }
}

// MARK: - HistoryEventRow

private struct HistoryEventRow: View {
    let event: CalendarEvent

    // Links from events that ended > 4h ago are considered likely expired.
    private var isExpired: Bool {
        event.end.timeIntervalSinceNow < -(4 * 3600)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body)
                    .lineLimit(1)
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let join = event.join {
                if isExpired {
                    Text("Link expirado")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Button("Entrar") {
                        NSWorkspace.shared.open(join.deepLinkURL ?? join.url)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: event.start)) – \(fmt.string(from: event.end))"
    }
}
