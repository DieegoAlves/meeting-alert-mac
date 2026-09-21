// OWNER: Sync module. Resolves a MeetingJoin from a raw Google Calendar event.
// Priority order per ARCHITECTURE contract:
//   1. conferenceData.entryPoints[type=="video"].uri  → .meet
//   2. hangoutLink                                    → .meet
//   3. regex over location, then description          → .zoom | .teams | .webex | .other
// deepLinkURL: set ONLY when the native app is installed on this machine.
// Zoom: zoommtg://zoom.us/join?confno=<id>&pwd=<pwd>  (derived from /j/<id>?pwd=<x>)
// Teams/Webex: use https URL (universal links route macOS to the installed app).
import Foundation
import Core

enum JoinResolver {

    // MARK: - Public entry point

    static func resolve(dto: RawEvent) -> MeetingJoin? {
        // 1. conferenceData video entryPoint
        if let uri = videoEntryPointURI(from: dto.conferenceData),
           let url = URL(string: uri), url.scheme?.hasPrefix("http") == true {
            return MeetingJoin(provider: .meet, url: url, deepLinkURL: nil)
        }

        // 2. hangoutLink
        if let link = dto.hangoutLink,
           let url = URL(string: link), url.scheme?.hasPrefix("http") == true {
            return MeetingJoin(provider: .meet, url: url, deepLinkURL: nil)
        }

        // 3. Scan location then description
        let candidates = [dto.location, dto.description].compactMap { $0 }
        for text in candidates {
            if let join = extractJoin(from: text) { return join }
        }

        return nil
    }

    // MARK: - conferenceData

    private static func videoEntryPointURI(from data: RawConferenceData?) -> String? {
        data?.entryPoints?.first { $0.entryPointType == "video" }?.uri
    }

    // MARK: - Regex extraction

    private static func extractJoin(from text: String) -> MeetingJoin? {
        if let url = firstMatch(zoomPattern,   in: text).flatMap(URL.init) {
            let deep = zoomDeepLinkURL(from: url)
            return MeetingJoin(provider: .zoom, url: url, deepLinkURL: deep)
        }
        if let url = firstMatch(teamsPattern,  in: text).flatMap(URL.init) {
            return MeetingJoin(provider: .teams, url: url, deepLinkURL: nil)
        }
        if let url = firstMatch(webexPattern,  in: text).flatMap(URL.init) {
            return MeetingJoin(provider: .webex, url: url, deepLinkURL: nil)
        }
        // Generic https URL fallback
        if let url = firstMatch(genericURLPattern, in: text).flatMap(URL.init) {
            return MeetingJoin(provider: .other, url: url, deepLinkURL: nil)
        }
        return nil
    }

    // MARK: - Regex patterns

    private static let zoomPattern = try! NSRegularExpression(
        pattern: #"https?://[\w\-]*\.?zoom\.us/(?:j|my|w)/[\w\-?&=.%]+"#
    )
    private static let teamsPattern = try! NSRegularExpression(
        pattern: #"https?://(?:teams\.microsoft\.com|teams\.live\.com)/l/meetup-join/\S+"#
    )
    private static let webexPattern = try! NSRegularExpression(
        pattern: #"https?://[\w\-]+\.webex\.com/(?:meet|join|wbxmjs)/\S+"#
    )
    private static let genericURLPattern = try! NSRegularExpression(
        pattern: #"https://[^\s<>\"']+"#
    )

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return Range(match.range, in: text).map { String(text[$0]) }
    }

    // MARK: - Zoom deep link

    /// Builds `zoommtg://zoom.us/join?confno=<id>&pwd=<pwd>` from an https Zoom URL.
    /// Returns nil when Zoom.app is not installed or the URL can't be parsed.
    private static func zoomDeepLinkURL(from httpsURL: URL) -> URL? {
        guard isZoomInstalled else { return nil }
        // Extract meeting ID from /j/<id> or /my/<id> etc.
        let path = httpsURL.path
        let components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
        guard let meetingID = extractMeetingID(from: path) else { return nil }
        var deepLink = "zoommtg://zoom.us/join?confno=\(meetingID)"
        if let pwd = components?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            deepLink += "&pwd=\(pwd)"
        }
        return URL(string: deepLink)
    }

    private static func extractMeetingID(from path: String) -> String? {
        // Matches /j/<digits>, /my/<alias>, /w/<id>
        let patterns = [
            #"^/j/(\d+)"#,
            #"^/w/(\d+)"#
        ]
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern)
            let ns = path as NSString
            if let m = regex?.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                if r.location != NSNotFound {
                    return ns.substring(with: r)
                }
            }
        }
        return nil
    }

    // MARK: - App detection

    // Checked once at first use; Zoom install doesn't change mid-session.
    static let isZoomInstalled: Bool = {
        let paths = [
            "/Applications/zoom.us.app",
            "\(NSHomeDirectory())/Applications/zoom.us.app"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }()
}
