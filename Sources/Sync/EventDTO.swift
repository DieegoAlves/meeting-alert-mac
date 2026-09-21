// OWNER: Sync module. JSON-decodable types for the Google Calendar v3 REST API.
import Foundation
import Core

// MARK: - Calendar List

struct CalendarListResponse: Decodable {
    let items: [CalendarListEntry]
    let nextPageToken: String?
}

struct CalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let accessRole: String?
    let primary: Bool?            // F-053: true for the account's primary calendar
    let backgroundColor: String?  // F-053: hex color, e.g. "#9fe1e7"
}

// MARK: - Events List

struct EventsListResponse: Decodable {
    let items: [RawEvent]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct RawEvent: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let start: RawEventTime?
    let end: RawEventTime?
    let hangoutLink: String?
    let location: String?
    let description: String?
    let conferenceData: RawConferenceData?
    let attendees: [RawAttendee]?

    var isCancelled: Bool { status == "cancelled" }
}

struct RawEventTime: Decodable {
    let dateTime: String?
    let date: String?
}

struct RawConferenceData: Decodable {
    let entryPoints: [RawEntryPoint]?
}

struct RawEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

struct RawAttendee: Decodable {
    let email: String
    let displayName: String?
    let responseStatus: String?
    // `self` is a reserved keyword — use backtick escape
    let isSelf: Bool?
    let organizer: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer
        case isSelf = "self"
    }
}

// MARK: - RawEvent → CalendarEvent

extension RawEvent {
    /// Returns nil for cancelled events or events with unparseable dates.
    func toCalendarEvent(calendarId: String) -> CalendarEvent? {
        guard !isCancelled,
              let startDate = parseEventDate(from: start),
              let endDate = parseEventDate(from: end)
        else { return nil }

        let isAllDay = start?.dateTime == nil && start?.date != nil

        let mappedAttendees: [Attendee] = (attendees ?? []).map { raw in
            let rs: ResponseStatus
            switch raw.responseStatus {
            case "accepted":  rs = .accepted
            case "declined":  rs = .declined
            case "tentative": rs = .tentative
            default:          rs = .needsAction
            }
            return Attendee(
                email: raw.email,
                displayName: raw.displayName,
                responseStatus: rs,
                isSelf: raw.isSelf ?? false,
                isOrganizer: raw.organizer ?? false
            )
        }

        return CalendarEvent(
            id: id,
            calendarId: calendarId,
            title: summary ?? "(No title)",
            start: startDate,
            end: endDate,
            attendees: mappedAttendees,
            location: location,
            description: description,
            isAllDay: isAllDay,
            join: nil // filled later by JoinResolver
        )
    }

    private func parseEventDate(from time: RawEventTime?) -> Date? {
        guard let time else { return nil }
        if let dt = time.dateTime { return EventDateParser.parseDateTime(dt) }
        if let d  = time.date     { return EventDateParser.parseDate(d) }
        return nil
    }
}

// MARK: - Date parsing helpers

private enum EventDateParser {
    static func parseDateTime(_ s: String) -> Date? {
        // Try with fractional seconds first, then without.
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: s)
    }

    static func parseDate(_ s: String) -> Date? {
        // All-day events carry only "yyyy-MM-dd"; map to local midnight.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }
}
