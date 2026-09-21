// OWNER: Core (frozen contract — do NOT edit after scaffold).
import Foundation

public struct CalendarEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let calendarId: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [Attendee]
    public let location: String?
    public let description: String?
    public let isAllDay: Bool
    public var join: MeetingJoin?          // resolved by Sync/JoinResolver

    public init(
        id: String,
        calendarId: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [Attendee],
        location: String?,
        description: String?,
        isAllDay: Bool,
        join: MeetingJoin? = nil
    ) {
        self.id = id
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.location = location
        self.description = description
        self.isAllDay = isAllDay
        self.join = join
    }
}
