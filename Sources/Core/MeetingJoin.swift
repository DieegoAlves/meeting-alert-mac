// OWNER: Core (frozen contract — do NOT edit after scaffold; every module imports this).
// Shared value type for a resolvable meeting join link.
import Foundation

public enum MeetingProvider: String, Codable, Sendable {
    case meet, zoom, teams, webex, other
}

public struct MeetingJoin: Codable, Hashable, Sendable {
    public let provider: MeetingProvider
    public let url: URL          // canonical https URL — always safe to open
    public let deepLinkURL: URL? // native scheme (e.g. zoommtg://) only if that app is installed

    public init(provider: MeetingProvider, url: URL, deepLinkURL: URL?) {
        self.provider = provider
        self.url = url
        self.deepLinkURL = deepLinkURL
    }
}

// Resolution rule (JoinResolver, priority order):
//  1. conferenceData.entryPoints[entryPointType=="video"].uri  → .meet
//  2. hangoutLink                                              → .meet
//  3. regex over location, then description → zoom | teams | webex (else .other if a URL found)
//  deepLinkURL: set ONLY when the native app is installed (LSCopyApplicationURLsForURL /
//  NSWorkspace.urlForApplication(toOpen:)); Zoom → zoommtg://…?confno&pwd derived from /j/<id>?pwd.
//  Otherwise deepLinkURL = nil and callers open `url` (https) via NSWorkspace.
