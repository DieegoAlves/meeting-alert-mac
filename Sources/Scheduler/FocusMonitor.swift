// OWNER: Scheduler module (Sources/Scheduler). Depends on Foundation only.
//
// Best-effort macOS Focus / Do-Not-Disturb detection with NO private API and zero dependencies:
// it reads the user's DoNotDisturb assertion store (the same JSON the system writes when a Focus is
// toggled on). If the file is unreadable (sandbox, changed layout, first run) it FAILS OPEN —
// `isActive() == false` — because for a meeting alert, firing when unsure beats silently missing a call.
import Darwin
import Foundation

struct FocusMonitor {
    /// True when a Focus / Do-Not-Disturb mode is currently active (manually or via Control Center).
    func isActive() -> Bool {
        guard
            let json = readJSON("Assertions.json"),
            let data = json["data"] as? [[String: Any]]
        else { return false }
        for entry in data {
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                return true
            }
        }
        return false
    }

    private func readJSON(_ name: String) -> [String: Any]? {
        let url = realHomeURL().appendingPathComponent("Library/DoNotDisturb/DB/\(name)")
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Returns the real user home directory. In a sandboxed app,
    /// FileManager.homeDirectoryForCurrentUser resolves to the container;
    /// getpwuid(getuid()) bypasses that redirection via the system account database.
    private func realHomeURL() -> URL {
        if let pw = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
