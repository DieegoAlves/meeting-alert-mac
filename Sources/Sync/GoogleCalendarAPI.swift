// OWNER: Sync module. Google Calendar v3 REST client (no SDK, URLSession only).
// Two sync lanes:
//   • windowed list  — timeMin/timeMax, no syncToken  → full refresh of retention window
//   • incremental    — syncToken + showDeleted=true   → cheap delta between polls; 410 → full resync
import Foundation

// MARK: - Errors

enum CalendarAPIError: Error {
    case syncTokenExpired       // HTTP 410 — drop token and do full resync
    case rateLimited            // HTTP 403/429 rate/quota — caller must back off
    case unauthenticated        // HTTP 401
    /// HTTP 403 accessNotConfigured / SERVICE_DISABLED — the Google Calendar API is not enabled
    /// in the project. Terminal (retrying is pointless); carries Google's activation URL. F-057.
    case apiDisabled(message: String, enableURL: String?)
    /// HTTP 403 `insufficientPermissions` — the access token was granted a scope too narrow for
    /// this request (e.g. `events.readonly` token calling calendarList.list). Terminal for the
    /// current credential: the caller must CLEAR it and re-consent with the wider scope. F-060.
    case insufficientScope(message: String)
    /// HTTP 403 that is NOT a rate limit and NOT api-disabled (e.g. insufficient scope). F-057.
    case forbidden(message: String)
    case httpError(Int)
    case invalidResponse
}

// Google's standard error envelope: {"error":{"code":403,"message":"…","status":"…",
// "errors":[{"reason":"accessNotConfigured","domain":"usageLimits"}]}}.
private struct GoogleErrorEnvelope: Decodable {
    struct Err: Decodable {
        struct Item: Decodable { let reason: String?; let domain: String? }
        let code: Int?
        let message: String?
        let status: String?
        let errors: [Item]?
    }
    let error: Err?
}

// MARK: - Google Calendar API actor

actor GoogleCalendarAPI {
    private let session: URLSession
    private static let base = "https://www.googleapis.com/calendar/v3"
    // Minimal field mask: only what we need to build CalendarEvent + JoinResolver
    private static let eventFields =
        "nextSyncToken,nextPageToken,items(id,status,summary,start,end," +
        "hangoutLink,location,description,conferenceData(entryPoints(entryPointType,uri)),attendees)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Calendar list

    func fetchCalendarList(token: String) async throws -> [CalendarListEntry] {
        var results: [CalendarListEntry] = []
        var pageToken: String? = nil

        repeat {
            var comps = URLComponents(string: "\(Self.base)/users/me/calendarList")!
            var qi: [URLQueryItem] = [
                .init(name: "maxResults", value: "250"),
                .init(name: "fields",     value: "nextPageToken,items(id,summary,accessRole,primary,backgroundColor)")
            ]
            if let pt = pageToken { qi.append(.init(name: "pageToken", value: pt)) }
            comps.queryItems = qi

            let data = try await get(url: comps.url!, token: token)
            let resp = try JSONDecoder().decode(CalendarListResponse.self, from: data)
            results.append(contentsOf: resp.items)
            pageToken = resp.nextPageToken
        } while pageToken != nil

        return results
    }

    // MARK: - Lane 1: windowed list (no syncToken)

    /// Fetches all non-cancelled events within [timeMin, timeMax].
    /// Returns events plus the nextSyncToken (use as seed for the incremental lane).
    func fetchWindowedEvents(
        calendarId: String,
        token: String,
        timeMin: Date,
        timeMax: Date
    ) async throws -> (events: [RawEvent], syncToken: String?) {
        var allItems: [RawEvent] = []
        var pageToken: String? = nil
        var syncToken: String? = nil

        repeat {
            var comps = URLComponents(string: "\(Self.base)/calendars/\(calendarId.urlPathEncoded)/events")!
            var qi: [URLQueryItem] = [
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy",      value: "startTime"),
                .init(name: "timeMin",      value: rfc3339(timeMin)),
                .init(name: "timeMax",      value: rfc3339(timeMax)),
                .init(name: "maxResults",   value: "2500"),
                .init(name: "fields",       value: Self.eventFields)
            ]
            if let pt = pageToken { qi.append(.init(name: "pageToken", value: pt)) }
            comps.queryItems = qi

            let data = try await get(url: comps.url!, token: token)
            let resp = try JSONDecoder().decode(EventsListResponse.self, from: data)
            allItems.append(contentsOf: resp.items ?? [])
            pageToken = resp.nextPageToken
            if pageToken == nil { syncToken = resp.nextSyncToken }
        } while pageToken != nil

        return (allItems, syncToken)
    }

    // MARK: - Lane 2: incremental (syncToken, no time bounds)

    /// Fetches incremental changes since the given syncToken.
    /// Throws CalendarAPIError.syncTokenExpired on HTTP 410.
    func fetchIncrementalEvents(
        calendarId: String,
        token: String,
        syncToken: String
    ) async throws -> (events: [RawEvent], nextSyncToken: String?) {
        var allItems: [RawEvent] = []
        var pageToken: String? = nil
        var nextSyncToken: String? = nil

        repeat {
            var comps = URLComponents(string: "\(Self.base)/calendars/\(calendarId.urlPathEncoded)/events")!
            var qi: [URLQueryItem] = [
                .init(name: "syncToken",    value: syncToken),
                .init(name: "showDeleted",  value: "true"),
                .init(name: "singleEvents", value: "true"),
                .init(name: "maxResults",   value: "2500"),
                .init(name: "fields",       value: Self.eventFields)
            ]
            if let pt = pageToken { qi.append(.init(name: "pageToken", value: pt)) }
            comps.queryItems = qi

            let data = try await get(url: comps.url!, token: token)
            let resp = try JSONDecoder().decode(EventsListResponse.self, from: data)
            allItems.append(contentsOf: resp.items ?? [])
            pageToken = resp.nextPageToken
            if pageToken == nil { nextSyncToken = resp.nextSyncToken }
        } while pageToken != nil

        return (allItems, nextSyncToken)
    }

    // MARK: - Low-level GET with exponential backoff on 403/429

    private func get(url: URL, token: String, attempt: Int = 0) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpMethod = "GET"

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw CalendarAPIError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            // Surface the EXACT Google error (status + message). Google returns a JSON body
            // {"error":{"code":403,"message":"...","status":"..."}}; without logging it, sync
            // failures are invisible and look like "still no events" to the user.
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<no body>"
            NSLog("[MeetingAlert] Calendar API HTTP \(http.statusCode) for \(url.path): \(body)")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw CalendarAPIError.unauthenticated
        case 410:
            throw CalendarAPIError.syncTokenExpired
        case 403:
            // F-057: a 403 is NOT always a rate limit. Classify by Google's reason so we don't
            // burn ~2 min of exponential backoff on a permanent condition (API disabled / no scope)
            // and then mislabel it "rateLimited". Only genuine quota/rate reasons back off & retry.
            let env     = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data)
            let reason  = env?.error?.errors?.first?.reason
            let message = env?.error?.message ?? "Acesso negado pelo Google (HTTP 403)."
            let rateReasons: Set<String> = [
                "rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "dailyLimitExceeded"
            ]
            if reason == "accessNotConfigured" || env?.error?.status == "SERVICE_DISABLED"
                || message.contains("has not been used in project")
                || message.contains("it is disabled") {
                throw CalendarAPIError.apiDisabled(message: message, enableURL: Self.firstURL(in: message))
            }
            // F-060: 403 `insufficientPermissions` == the token's granted scope is too narrow for
            // this call (the calendarList.list failure Diego hit). NOT a rate limit and NOT
            // recoverable by retrying — the caller must clear the credential and re-consent.
            if reason == "insufficientPermissions"
                || message.localizedCaseInsensitiveContains("insufficient authentication scopes")
                || message.localizedCaseInsensitiveContains("insufficient permission") {
                throw CalendarAPIError.insufficientScope(message: message)
            }
            if let reason, rateReasons.contains(reason) {
                guard attempt < 5 else { throw CalendarAPIError.rateLimited }
                let backoff = min(pow(2.0, Double(attempt)) + Double.random(in: 0..<1), 64.0)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                return try await get(url: url, token: token, attempt: attempt + 1)
            }
            throw CalendarAPIError.forbidden(message: message)
        case 429:
            guard attempt < 5 else { throw CalendarAPIError.rateLimited }
            let backoff = min(pow(2.0, Double(attempt)) + Double.random(in: 0..<1), 64.0)
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            return try await get(url: url, token: token, attempt: attempt + 1)
        default:
            throw CalendarAPIError.httpError(http.statusCode)
        }
    }

    /// Extracts the first http(s) URL from a Google error message (the "Enable it by visiting …"
    /// activation link), trimming trailing punctuation. F-057.
    private static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: "https?://[^\\s]+", options: .regularExpression) else { return nil }
        var url = String(text[range])
        while let last = url.last, ".,);]'\"".contains(last) { url.removeLast() }
        return url
    }
}

// MARK: - Helpers

private func rfc3339(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
