// OWNER: Auth module. POSIX BSD-socket TCP listener on 127.0.0.1:<ephemeral> for the OAuth redirect.
//
// F-055: this was previously built on Network.framework (`NWListener`). On macOS 26 (Darwin 25.6)
// `NWListener` fails to bind with NWError 22 (EINVAL) for EVERY parameter combination — even a
// plain `NWListener(using: .tcp, on: .any)` — inside the sandboxed app, despite the
// `com.apple.security.network.server` entitlement being present. A plain POSIX socket bound to
// 127.0.0.1:0 binds and listens correctly in the same context, so the loopback redirect server is
// implemented directly on BSD sockets. This also keeps the F-043 guarantee (loopback-only) in the
// strongest possible form: the socket is bound explicitly to 127.0.0.1, never 0.0.0.0.
import Foundation
import Core
#if canImport(Darwin)
import Darwin
#endif

final class LoopbackRedirectServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "com.meetingalert.loopback", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    private init(listenFD: Int32, port: UInt16) {
        self.listenFD = listenFD
        self.port = port
    }

    /// Binds a listener on an ephemeral loopback TCP port and returns once it is listening.
    static func start() async throws -> LoopbackRedirectServer {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw AuthError.loopbackFailed("socket() failed (errno \(errno))") }

        // Allow immediate reuse so a rapid retry after a cancelled sign-in doesn't hit TIME_WAIT.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                              // OS assigns an ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // F-043: loopback ONLY, never 0.0.0.0

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw AuthError.loopbackFailed("bind(127.0.0.1) failed (errno \(errno))")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw AuthError.loopbackFailed("listen() failed (errno \(errno))")
        }

        // Read back the OS-assigned port.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw AuthError.loopbackFailed("getsockname() failed (errno \(errno))")
        }
        let assignedPort = UInt16(bigEndian: bound.sin_port)
        return LoopbackRedirectServer(listenFD: fd, port: assignedPort)
    }

    /// Waits for the browser redirect, validates `state` (CSRF), and returns the authorization code.
    /// Times out after `timeout` seconds (default 5 min).
    func waitForCode(expectedState: String, timeout: TimeInterval = 300) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                try await self.acceptLoop(expectedState: expectedState)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AuthError.loopbackFailed("OAuth redirect timed out after \(Int(timeout)) seconds")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func cancel() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !alreadyCancelled else { return }
        close(listenFD)   // unblocks a blocking accept() in the loop
    }

    // MARK: - Private

    /// How the current connection's request line classifies.
    private enum RedirectOutcome {
        case code(String)    // valid redirect (code present, state matches) → complete the flow
        case error(String)   // callback carries ?error=… (e.g. access_denied) → surface it, abort
        case csrf            // state present but mismatched → hard CSRF failure, abort the flow
        case ignore          // spurious/partial/non-redirect (favicon, probe, no code) → keep listening
    }

    /// Accepts connections until the genuine OAuth redirect arrives (or a hard CSRF failure).
    /// Spurious/partial connections are dropped and the loop keeps waiting (bounded by the 5-min
    /// timeout in `waitForCode`). F-045.
    private func acceptLoop(expectedState: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    while true {
                        let clientFD = accept(listenFD, nil, nil)
                        if clientFD < 0 {
                            lock.lock(); let c = cancelled; lock.unlock()
                            if c { cont.resume(throwing: AuthError.loopbackFailed("Listener cancelled")); return }
                            if errno == EINTR { continue }
                            cont.resume(throwing: AuthError.loopbackFailed("accept() failed (errno \(errno))")); return
                        }

                        // Bound the per-connection read so a silent probe can't wedge the loop.
                        var tv = timeval(tv_sec: 5, tv_usec: 0)
                        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                        guard let raw = Self.readRequestLine(clientFD) else {
                            close(clientFD)
                            continue   // partial/timed-out → not the redirect; keep listening
                        }

                        switch Self.classify(request: raw, expectedState: expectedState) {
                        case .code(let code):
                            Self.sendSuccess(clientFD)
                            close(clientFD)
                            cont.resume(returning: code)
                            return
                        case .error(let detail):
                            // F-056: Google (or the user) returned via the callback with ?error=…
                            // Show it in the browser tab AND fail the flow immediately with the exact
                            // reason, instead of silently ignoring and hanging until the 5-min timeout.
                            Self.sendError(clientFD, detail: detail)
                            close(clientFD)
                            cont.resume(throwing: AuthError.loopbackFailed(detail))
                            return
                        case .csrf:
                            close(clientFD)
                            cont.resume(throwing: AuthError.loopbackFailed("State mismatch — possible CSRF attack"))
                            return
                        case .ignore:
                            close(clientFD)
                            continue
                        }
                    }
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    /// Reads from the connection until the first CRLF (the HTTP request line holds every OAuth
    /// param — it's a GET). Handles TCP segmentation. Returns nil on EOF/error before a full line.
    private static func readRequestLine(_ fd: Int32) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 65536 {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return nil }   // EOF, timeout (EAGAIN), or error
            buffer.append(contentsOf: chunk[0..<n])
            if let s = String(bytes: buffer, encoding: .utf8), s.range(of: "\r\n") != nil {
                return s
            }
        }
        return nil
    }

    private static func sendSuccess(_ fd: Int32) {
        let html = """
            <html><head><title>Meeting Alert</title></head>\
            <body style="font-family:sans-serif;text-align:center;padding:60px">\
            <h2>Authorization complete</h2>\
            <p>You may close this tab and return to Meeting Alert.</p>\
            </body></html>
            """
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            html
        let bytes = [UInt8](response.utf8)
        var offset = 0
        bytes.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while offset < bytes.count {
                let sent = send(fd, base + offset, bytes.count - offset, 0)
                if sent <= 0 { break }
                offset += sent
            }
        }
    }

    private static func classify(request: String, expectedState: String) -> RedirectOutcome {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET ") else {
            return .ignore
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://localhost" + parts[1]),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else {
            return .ignore
        }
        var code: String?
        var state: String?
        var error: String?
        var errorDescription: String?
        for item in items {
            switch item.name {
            case "code":              code             = item.value
            case "state":             state            = item.value
            case "error":             error            = item.value
            case "error_description": errorDescription = item.value
            default: break
            }
        }
        // F-056: an OAuth *error* callback (?error=access_denied&…) is a real, terminal response —
        // surface it. Google percent-encodes error_description with '+' for spaces; decode both.
        if let error, !error.isEmpty {
            let desc = errorDescription?.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
            let detail = desc.map { "Google recusou: \(error) — \($0)" } ?? "Google recusou: \(error)"
            return .error(detail)
        }
        // Only a *mismatched* state is a hard CSRF failure. A missing state (or missing code)
        // just means this isn't the OAuth callback — ignore and keep listening.
        if let state, state != expectedState {
            return .csrf
        }
        guard let code, let state, state == expectedState else {
            return .ignore
        }
        return .code(code)
    }

    /// Sends a minimal error page so the browser tab shows the failure rather than a dead
    /// connection, then the flow aborts with the same detail. F-056.
    private static func sendError(_ fd: Int32, detail: String) {
        let safe = detail
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
            <html><head><title>Meeting Alert</title></head>\
            <body style="font-family:sans-serif;text-align:center;padding:60px">\
            <h2>Falha na autorização</h2>\
            <p>\(safe)</p>\
            <p>Você pode fechar esta aba e voltar ao Meeting Alert.</p>\
            </body></html>
            """
        let response =
            "HTTP/1.1 400 Bad Request\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            html
        let bytes = [UInt8](response.utf8)
        var offset = 0
        bytes.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while offset < bytes.count {
                let sent = send(fd, base + offset, bytes.count - offset, 0)
                if sent <= 0 { break }
                offset += sent
            }
        }
    }
}
