# Google Calendar API + OAuth for a Native macOS Menu-Bar App (Swift, no Google SDK)

**Scope:** local build, single user, no App Store, macOS 14+. No Google client library — talk to the REST/OAuth endpoints directly with `URLSession`.
**Date:** 2026-09-15. Every factual claim is sourced inline as [TITLE](URL). Items marked **[inference]** are engineering judgement, not doc-sourced.

> **Skill note:** the bound skills `oc-browser` and `overclock-research-cite` return *Unknown* on this install. Per the caller's mid-turn confirmation, research was done with native WebFetch/WebSearch against the live docs and the citation rule applied directly. This is sanctioned, not an imitation.

---

## 1. OAuth 2.0 for a native desktop app WITHOUT Google's SDK

### Recommended decision
Use the **installed-app / loopback-IP redirect flow with PKCE**. Register a **Desktop app** OAuth client in Google Cloud. Drive the flow yourself and host a tiny local HTTP listener on `127.0.0.1:<ephemeral-port>`. Store the **refresh token in the macOS Keychain**. Use scope **`calendar.events.readonly`** (narrowest that still reads events).

### Flow mechanics (exact)

Authorization endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
Token endpoint: `https://oauth2.googleapis.com/token`
([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

**PKCE** is mandatory for this flow:
- `code_verifier`: high-entropy random string, unreserved chars `[A-Z] [a-z] [0-9] "-" "." "_" "~"`, length **43–128**.
- `code_challenge_method=S256` (recommended) → `code_challenge` = Base64URL(no padding) of SHA-256(code_verifier). `plain` also allowed but not recommended.
([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

**Authorization request** parameters (browser/redirect):
`client_id`, `response_type=code`, `redirect_uri`, `scope` (space-delimited), `code_challenge`, `code_challenge_method`, and (recommended) `state` for CSRF. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))
To actually receive a **refresh token**, also add `access_type=offline` and, to force re-consent when needed, `prompt=consent`. **[inference — standard Google OAuth requirement; the native-app page focuses on the code exchange, not these two params]**

**Redirect URI — loopback:** query the platform for the loopback IP and start an HTTP listener on a **random available port**:
- IPv4: `http://127.0.0.1:<port>`
- IPv6: `http://[::1]:<port>`
`localhost` may be used instead but "may cause issues with client firewalls." Loopback redirect is **deprecated on mobile** but remains the supported path for desktop. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

**Token exchange** (POST `oauth2.googleapis.com/token`):
`client_id`, `code`, `code_verifier`, `grant_type=authorization_code`, `redirect_uri` (must match). `client_secret` is *Optional* and "not applicable to requests from clients registered as Android, iOS, or Chrome applications" — a **Desktop app** client is issued a client secret, but PKCE is what actually secures the exchange. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

**Successful response:** `access_token`, `refresh_token`, `expires_in` (seconds), `token_type: Bearer`. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

**Refresh exchange** (POST `oauth2.googleapis.com/token`):
`client_id`, `grant_type=refresh_token`, `refresh_token`. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

### Client-type registration
Create an OAuth client of type **Desktop app** in Google Cloud Console. No bundle ID / store ID needed (those are iOS/Android). ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

### ASWebAuthenticationSession vs. system browser

| | **ASWebAuthenticationSession** | **Open system default browser + loopback listener** |
|---|---|---|
| Redirect capture | Native callback via a **custom URL scheme** (`callbackURLScheme:`); no local server needed | You run an `NSXPC`/`Network.framework` HTTP listener on `127.0.0.1:<port>` to catch the `code` |
| UX | In-app modal sheet, ephemeral session option, Apple-blessed | Full browser tab; user context-switches |
| Cookie reuse | Can share or isolate Safari cookies (`prefersEphemeralWebSession`) | Uses whatever the user's default browser session is |
| Fit with Google loopback | Google's *documented* desktop flow is loopback (`http://127.0.0.1`), not a custom scheme; ASWebAuthenticationSession wants a scheme callback | Matches Google's documented desktop flow exactly |

**Recommendation:** **[inference]** For strict adherence to Google's documented desktop flow, use the **loopback listener + open the system browser** (`NSWorkspace.shared.open`). `ASWebAuthenticationSession` is cleaner UX but is designed around a **custom-scheme** callback; to use it you'd register a custom URI scheme redirect (also supported by Google for installed apps per the same page's "Custom URI scheme" option) instead of loopback. Either is acceptable; pick **loopback+system-browser** for the least surprising Google behavior, or **ASWebAuthenticationSession+custom-scheme** if you prefer no local socket. Do **not** use a `WKWebView` — Google blocks embedded webviews for OAuth (`disallowed_useragent`). **[inference]**

### Scope choice: `calendar.readonly` vs `calendar.events.readonly`
- `https://www.googleapis.com/auth/calendar.events.readonly` — "View events on all your calendars."
- `https://www.googleapis.com/auth/calendar.readonly` — "See and download any calendar you can access" (broader: calendar metadata, ACLs, calendar list).
([Choose Auth Scopes — Calendar API](https://developers.google.com/calendar/api/auth))

**Recommendation:** use **`calendar.events.readonly`** — it is sufficient to call `events.list`/`calendarList.list` for reading upcoming meetings and is the narrower, more trust-friendly scope; Google advises selecting "the most narrowly focused scope possible." ([Choose Auth Scopes — Calendar API](https://developers.google.com/calendar/api/auth)) Both are **sensitive** scopes requiring verification for public apps — but for a **local single-user Testing app** you can add your own account as a **test user** and skip verification (see refresh-token caveat below).

### Refresh-token handling & secure storage
- **Access-token lifetime** is returned in `expires_in`; refresh when expired or ~1 min before. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))
- **CRITICAL for a personal/Testing app:** "A Google Cloud Platform project with an OAuth consent screen configured for an external user type and a publishing status of **'Testing'** is issued a refresh token expiring in **7 days**." ([Using OAuth 2.0 to Access Google APIs](https://developers.google.com/identity/protocols/oauth2)) → **Set the OAuth consent screen to "In production"** (or use an **Internal** user type on a Workspace org) so the refresh token is long-lived; otherwise the user must re-auth weekly. **[inference on the "set to production" fix; the 7-day fact is sourced]**
- Refresh token also dies if **unused for 6 months**, on user revoke, or on password change with Gmail scopes; there is a **limit of 100 refresh tokens per Google Account per client ID** (oldest auto-invalidated). ([Using OAuth 2.0 to Access Google APIs](https://developers.google.com/identity/protocols/oauth2))
- **Storage:** put the refresh token (and optionally the current access token) in the **macOS Keychain** via the Security framework / `SecItem*` APIs, item class `kSecClassGenericPassword`, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrAccessControl` if you want. **[inference — Keychain is the platform-standard secret store; not a Calendar-API doc fact]**

### Risks
- Forgetting to promote the consent screen out of "Testing" → weekly forced re-login (7-day token). ([Using OAuth 2.0 to Access Google APIs](https://developers.google.com/identity/protocols/oauth2))
- Embedded webview → `disallowed_useragent` block. **[inference]**
- Loopback listener must bind an **ephemeral** port and validate `state` to prevent CSRF/port-hijack. ([OAuth 2.0 for Mobile & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))

---

## 2. Reading events

### Recommended decision
`GET https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events` with `singleEvents=true`, `orderBy=startTime`, and a `timeMin`/`timeMax` window; maintain **incremental sync with `syncToken`** and handle **410 → full resync**. ([Events: list — Calendar API](https://developers.google.com/calendar/api/v3/reference/events/list))

### Parameters (exact)
Endpoint: `GET https://www.googleapis.com/calendar/v3/calendars/calendarId/events` (use `calendarId=primary` for the user's main calendar). ([Events: list — Calendar API](https://developers.google.com/calendar/api/v3/reference/events/list))

- `singleEvents` (bool, default false) — "expand recurring events into instances and only return single one-off events." Set **true**. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `orderBy` — allowed `startTime` or `updated`; **`startTime` is only valid when `singleEvents=true`.** ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `timeMin` (RFC3339) — lower bound (**exclusive**) on an event's **end** time. Format `2011-06-03T10:00:00-07:00` or `...Z`; timezone offset mandatory. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `timeMax` (RFC3339) — upper bound (**exclusive**) on an event's **start** time; must be `> timeMin`. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `maxResults` (int, default **250**, max **2500**); `pageToken` for pagination. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `showDeleted` (bool) — include `status=cancelled` entries (needed on incremental sync to remove them). ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `timeZone` (string) — response TZ, defaults to calendar TZ. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
- `fields` — partial response mask (see below).

**Today + tomorrow window (example):**
```
GET /calendar/v3/calendars/primary/events
  ?singleEvents=true
  &orderBy=startTime
  &timeMin=2026-09-15T00:00:00-03:00
  &timeMax=2026-09-17T00:00:00-03:00
  &maxResults=250
  &fields=nextSyncToken,nextPageToken,items(id,status,summary,start,end,hangoutLink,location,description,conferenceData)
Authorization: Bearer <access_token>
```
**[inference on exact field list & datetimes; params/format sourced above]**

### Incremental sync with `syncToken`
- Initial **full sync**: normal list; response returns **`nextSyncToken`** — persist it. ([Synchronize Resources Efficiently — Calendar API](https://developers.google.com/calendar/api/guides/sync))
- Later **incremental sync**: pass stored token as `syncToken`; you get only changes, including deleted entries. ([Synchronize Resources Efficiently](https://developers.google.com/calendar/api/guides/sync))
- `syncToken` is **incompatible** with `iCalUID`, `orderBy`, `privateExtendedProperty`, `q`, `sharedExtendedProperty`, `timeMin`, `timeMax`, `updatedMin` — using them returns **400**. Each incremental request must use the **same query params as the initial one**. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list) · [Sync guide](https://developers.google.com/calendar/api/guides/sync))
- Large change sets paginate with `pageToken`; only the **final page** carries the new `nextSyncToken`. ([Sync guide](https://developers.google.com/calendar/api/guides/sync))

> **Design tension:** because `syncToken` forbids `timeMin/timeMax`, you cannot both window (today+tomorrow) *and* incrementally sync in the same call. **Recommended pattern [inference]:** run a **windowed, non-syncToken** `events.list` (singleEvents+orderBy+timeMin/timeMax) on your polling cadence for the UI, and — if you want change-efficient background sync — keep a **separate** full-calendar syncToken loop (`singleEvents=true`, `showDeleted=true`, no time window) and filter to the window client-side.

### Handling 410 GONE
If a `syncToken` expires the server returns **410 GONE**; **clear the stored token and cached events, then do a fresh full sync.** ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list) · [Sync guide](https://developers.google.com/calendar/api/guides/sync))

### Recommended `fields`
`nextSyncToken,nextPageToken,items(id,status,summary,start,end,hangoutLink,location,description,conferenceData)` — trims payload to what a meeting alert needs. Partial response via `fields` is a standard Calendar API optimization. **[inference on the exact mask; `fields` param itself is documented on Events: list]**

---

## 3. Meeting links (Meet / Zoom / Teams / Webex)

### Recommended decision
Extract in priority order: **`conferenceData.entryPoints[]` (entryPointType `video`) → `hangoutLink` → regex over `location` → regex over `description`.** Prefer opening the vendor's **https** URL and let macOS route it to the installed app; use native deep-link schemes only as an optimization.

### Google Meet — structured, reliable
The Event resource carries:
```json
"hangoutLink": "https://meet.google.com/abc-defg-hij",
"conferenceData": {
  "conferenceId": "abc-defg-hij",
  "conferenceSolution": { "key": { "type": "hangoutsMeet" }, "name": "...", "iconUri": "..." },
  "entryPoints": [
    { "entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij", "label": "meet.google.com/abc-defg-hij" },
    { "entryPointType": "phone", "uri": "tel:+1-...", "pin": "..." },
    { "entryPointType": "sip",   "uri": "sip:...", "pin": "..." },
    { "entryPointType": "more",  "uri": "https://tel.meet/..." }
  ],
  "notes": "string"
}
```
`entryPointType` values: **`video`, `phone`, `sip`, `more`**; entry-point fields include `uri`, `label`, `meetingCode`, `passcode`, `accessCode`, `pin`. `conferenceSolution.key.type` values include `hangoutsMeet`, `addOn`, `eventHangout`, `eventNamedHangout`. ([Events resource — Calendar API](https://developers.google.com/calendar/api/v3/reference/events))
→ For Meet, take the `entryPoints` element with `entryPointType == "video"` and use its `uri`; fall back to `hangoutLink`. ([Events resource](https://developers.google.com/calendar/api/v3/reference/events))

### Zoom / Teams / Webex — where links live
Third-party conferencing added via an add-on **may** populate `conferenceData` with `conferenceSolution.key.type == "addOn"` and an `entryPoints[video].uri`. ([Events resource](https://developers.google.com/calendar/api/v3/reference/events)) But many invites only put the link in **`location`** or **`description`** free text, so parse both robustly. **[inference — common real-world behavior; not a single doc statement]**

Robust extraction regexes **[inference]**:
- **Zoom:** `https?://[\w-]*\.?zoom\.us/j/(\d+)(\?pwd=[\w.-]+)?` (also `/my/`, `/w/`).
- **Teams:** `https?://teams\.microsoft\.com/l/meetup-join/\S+` (and `teams.live.com`).
- **Webex:** `https?://[\w-]+\.webex\.com/(meet|join)/\S+` (and `/wbxmjs/`).

### Native deep links vs. web fallback
- **Zoom:** `zoommtg://zoom.us/join?confno=<MEETING_ID>&pwd=<PASSCODE>` launches the desktop client; does nothing if Zoom isn't installed. ([Zoom URL Scheme Query — Zoom Developer Forum](https://devforum.zoom.us/t/zoom-url-scheme-query/50832) · [Opens a zoom meeting from the command line — GitHub gist](https://gist.github.com/brycemcd/04092405cbc663ee7ea48b933e40844e)) Derive `confno`/`pwd` from the `/j/<id>?pwd=<x>` web URL.
- **Teams:** native scheme `msteams://` / `msteams:` **[inference — Microsoft deep-link scheme, not verified against a fetched Microsoft doc this session]**.
- **Webex:** native scheme `webex://` / `wbx://` **[inference — not verified against a fetched Webex doc this session]**.

**Recommendation [inference]:** don't hand-build native schemes for Teams/Webex. On macOS just call `NSWorkspace.shared.open(URL)` on the vendor's **https** meeting URL — macOS routes registered `https` universal links to the installed Zoom/Teams/Webex app automatically, and cleanly falls back to the browser when the app is absent. Reserve the `zoommtg://` construction for Zoom, where it's well-documented and lets you pre-fill the passcode.

### Risks
- Add-on conferencing may **not** populate `conferenceData`, so text-parsing `location`/`description` is required as a fallback. **[inference]**
- Native schemes silently no-op without the app installed → always keep the https fallback. ([Zoom URL Scheme Query](https://devforum.zoom.us/t/zoom-url-scheme-query/50832))

---

## 4. Quotas / limits, safe polling, and "already started" detection

### Quotas (exact)
- **10,000 requests/minute per project.**
- **600 requests/minute per user per project.**
- **1,000,000 requests/day per project** before billing threshold.
([Manage Quotas — Calendar API](https://developers.google.com/calendar/api/guides/quota))

Rate-limit errors: **`403`** or **`429`** with reason **`usageLimits`** / `rateLimitExceeded`. Retry with **exponential backoff**: `min((2^n + random_ms), maximum_backoff)`, `random_ms ≤ 1000`, `maximum_backoff` ~32–64s, then stop increasing. ([Manage Quotas — Calendar API](https://developers.google.com/calendar/api/guides/quota))

### Safe polling interval (single user)
With a 600 req/min/user ceiling, a single-user app has enormous headroom. **Recommendation [inference]:** poll every **60 s** during the workday (≈1 req/min, ~0.17% of the per-user budget), optionally **30 s** in the ~5-minute pre-meeting window; back off to **5 min** when idle/offscreen. Use **`syncToken`** to keep each poll cheap, and honor **429/403 backoff**. Prefer **push notifications (`events.watch` channels)** if you want near-real-time without polling, but for a personal menu-bar app a 60 s poll is simpler and well within quota. **[inference; quota numbers sourced above]**

### Detecting "a meeting has ALREADY started" (late-join history: today + last 7 days)
No dedicated API flag — compute it client-side **[inference]**:
1. Pull events for the window **`timeMin = now − 7 days`**, **`timeMax = end of today`**, with `singleEvents=true`, `orderBy=startTime`. (RFC3339, exclusive bounds per §2.) ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))
2. For each item parse `start.dateTime` / `end.dateTime`. A meeting is **already started (joinable now)** when `start.dateTime ≤ now < end.dateTime`; it's **late-join history** when `end.dateTime < now` within the last 7 days.
3. Keep only events that yielded a meeting link (§3) and skip `status == "cancelled"`. ([Events resource](https://developers.google.com/calendar/api/v3/reference/events))
4. All-day events use `start.date`/`end.date` (no time) — exclude or treat separately. **[inference]**

Because this history window is fixed and small, a **windowed non-syncToken list** (which allows `timeMin/timeMax`) is the right call here rather than the syncToken loop. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list))

### Risks
- Bursty polling across many calendars could approach the 600/min/user cap — batch or stagger. ([Manage Quotas](https://developers.google.com/calendar/api/guides/quota))
- Not honoring `Retry-After`/backoff on 429 risks temporary lockout. ([Manage Quotas](https://developers.google.com/calendar/api/guides/quota))

---

## Summary of recommended decisions
1. **OAuth:** Desktop-app client + **PKCE (S256)** + **loopback `127.0.0.1:<ephemeral>`** redirect, open the **system browser** (or ASWebAuthenticationSession w/ custom scheme). Scope **`calendar.events.readonly`**. Refresh token in **Keychain**. **Promote consent screen to Production/Internal** to avoid the **7-day Testing-token** expiry. ([native-app](https://developers.google.com/identity/protocols/oauth2/native-app) · [oauth2](https://developers.google.com/identity/protocols/oauth2) · [auth scopes](https://developers.google.com/calendar/api/auth))
2. **Reading:** `events.list` with `singleEvents=true&orderBy=startTime&timeMin&timeMax`; trim with `fields`; keep a separate **syncToken** loop and handle **410→full resync**. ([Events: list](https://developers.google.com/calendar/api/v3/reference/events/list) · [sync](https://developers.google.com/calendar/api/guides/sync))
3. **Links:** `conferenceData.entryPoints[video].uri` → `hangoutLink` → regex `location`/`description`; open vendor **https** URL via `NSWorkspace` (Zoom optional `zoommtg://`). ([Events resource](https://developers.google.com/calendar/api/v3/reference/events) · [Zoom scheme](https://devforum.zoom.us/t/zoom-url-scheme-query/50832))
4. **Quota/polling:** budget is 600 req/min/user; poll **~60 s** (30 s pre-meeting, 5 min idle) with backoff on **403/429**; detect started meetings by `start ≤ now < end`. ([Manage Quotas](https://developers.google.com/calendar/api/guides/quota))
