// OWNER: Core (frozen contract — do NOT edit after scaffold).
import Foundation

public enum ResponseStatus: String, Codable, Sendable {
    case accepted, declined, tentative, needsAction
}

public struct Attendee: Codable, Hashable, Sendable {
    public let email: String
    public let displayName: String?
    public let responseStatus: ResponseStatus
    public let isSelf: Bool
    public let isOrganizer: Bool

    public init(
        email: String,
        displayName: String?,
        responseStatus: ResponseStatus,
        isSelf: Bool,
        isOrganizer: Bool
    ) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
    }
}
