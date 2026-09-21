// OWNER: Core (frozen contract — do NOT edit after scaffold).
// Sync WRITES, MenuBar/Scheduler READ. Retention window = 7 days back … end of tomorrow.
// Fully implemented in the scaffold: it is shared infrastructure, not a per-module stub.
import Foundation
import Combine

@MainActor
public final class EventStore: ObservableObject {
    public static let shared = EventStore()

    /// Within retention window, sorted by start ascending.
    @Published public private(set) var events: [CalendarEvent] = []

    /// Posted after every mutation (replaceAll / apply).
    public static let didChangeNotification = Notification.Name("EventStore.didChangeNotification")

    private var persistWorkItem: DispatchWorkItem?

    public init() {}

    // MARK: - Mutation (Sync)

    /// Full sync — replaces the whole windowed set.
    public func replaceAll(_ events: [CalendarEvent]) {
        self.events = Self.windowed(events)
        didMutate()
    }

    /// Incremental sync — upsert by id, remove by id, then re-window + re-sort.
    public func apply(upserts: [CalendarEvent], removedIDs: [String]) {
        var map = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for id in removedIDs { map[id] = nil }
        for e in upserts { map[e.id] = e }
        self.events = Self.windowed(Array(map.values))
        didMutate()
    }

    // MARK: - Reads (MenuBar / Scheduler)

    public func events(in interval: DateInterval) -> [CalendarEvent] {
        events.filter { event in
            let end = max(event.start, event.end)
            return interval.intersects(DateInterval(start: event.start, end: end))
        }
    }

    /// start <= now < end
    public var active: [CalendarEvent] {
        let now = Date()
        return events.filter { $0.start <= now && now < $0.end }
    }

    /// start > now, today + tomorrow
    public var upcoming: [CalendarEvent] {
        let now = Date()
        let horizon = Self.endOfTomorrow(from: now)
        return events.filter { $0.start > now && $0.start <= horizon }
    }

    /// end < now, within the last 7 days
    public var history: [CalendarEvent] {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return events.filter { $0.end < now && $0.end >= cutoff }
    }

    // MARK: - Persistence

    /// Load cached events from Application Support JSON at launch.
    public func load() {
        guard
            let data = try? Data(contentsOf: AppPaths.eventStoreURL),
            let decoded = try? JSONDecoder.meetingAlert.decode([CalendarEvent].self, from: data)
        else { return }
        self.events = Self.windowed(decoded)
    }

    /// Debounced JSON write (Core owns AppPaths.eventStoreURL).
    public func persist() {
        persistWorkItem?.cancel()
        let snapshot = events
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.meetingAlert.encode(snapshot) else { return }
            try? AppPaths.ensureAppSupportDirectory()
            try? data.write(to: AppPaths.eventStoreURL, options: .atomic)
        }
        persistWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Helpers

    private func didMutate() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        persist()
    }

    /// Keep only events overlapping [now-7d … end of tomorrow], sorted by start.
    private static func windowed(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let now = Date()
        let lowerBound = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let upperBound = endOfTomorrow(from: now)
        return events
            .filter { $0.end >= lowerBound && $0.start <= upperBound }
            .sorted { $0.start < $1.start }
    }

    /// Start of the day after tomorrow (exclusive upper bound of "today + tomorrow").
    private static func endOfTomorrow(from date: Date) -> Date {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 2, to: startOfToday) ?? date
    }
}
