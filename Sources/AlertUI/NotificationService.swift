// OWNER: AlertUI module (Sources/AlertUI). Depends on Core ONLY.
//
// NotificationService is the T-5min ("notify") stage: a `.timeSensitive` UNUserNotification that
// breaks through Focus without needing Apple's Critical entitlement (research/02 §4). It owns the
// UNUserNotificationCenter category (Entrar / Adiar 1 / Adiar 5 / Já estou na call) and the
// delegate that routes the user's chosen action back into the Scheduler via `AlertScheduling`.
//
// The Scheduler is not implemented yet; this class holds it weakly through the `AlertScheduling`
// protocol and simply no-ops the routing until it is wired by the composition root.
import Foundation
import UserNotifications
import Core

@MainActor
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let categoryID = "MEETING_ALERT"

    private enum ActionID {
        static let join = "JOIN"
        static let snooze1 = "SNOOZE_1"
        static let snooze5 = "SNOOZE_5"
        static let already = "ALREADY_IN_CALL"
    }

    /// Weak to avoid a retain cycle: Scheduler holds the Presenter which owns this service.
    weak var scheduler: AlertScheduling?

    /// Notification identifier → the group it represents, so a tapped action can be routed back.
    private var groupsByRequestID: [String: AlertGroup] = [:]

    public override init() { super.init() }

    // MARK: - Setup (call once at launch from the composition root)

    /// Register the actionable category and request authorization. Idempotent.
    func registerCategories() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let join = UNNotificationAction(identifier: ActionID.join, title: "Entrar", options: [.foreground])
        let snooze1 = UNNotificationAction(identifier: ActionID.snooze1, title: "Adiar 1 min", options: [])
        let snooze5 = UNNotificationAction(identifier: ActionID.snooze5, title: "Adiar 5 min", options: [])
        let already = UNNotificationAction(identifier: ActionID.already, title: "Já estou na call", options: [])

        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [join, snooze1, snooze5, already],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Present (called by AlertPresenter for the .notify stage)

    /// Deliver the T-5 notification immediately — the Scheduler already fired its timer at the
    /// correct instant, so no UN trigger delay is needed.
    func present(_ group: AlertGroup) {
        deliver(group, silent: false)
    }

    /// F-052: deliver a silent, passive notification (no sound, no Focus break-through) —
    /// the downgrade path for a T-1 overlay while a Focus mode is active.
    func presentSilent(_ group: AlertGroup) {
        deliver(group, silent: true)
    }

    private func deliver(_ group: AlertGroup, silent: Bool) {
        // Prune entries for meetings that have already started (with a 30-min grace).
        // This bounds groupsByRequestID to at most the events presented since the last
        // meeting started, preventing unbounded growth over long uptimes.
        let pruneThreshold = Date().addingTimeInterval(-1800)
        groupsByRequestID = groupsByRequestID.filter { _, g in
            g.events.contains { $0.start > pruneThreshold }
        }

        let content = UNMutableNotificationContent()
        let titles = group.events.map(\.title)

        if group.events.count == 1, let event = group.events.first {
            content.title = event.title
            content.body = "Começa às \(Self.timeString(event.start))"
        } else {
            content.title = "\(group.events.count) reuniões em breve"
            content.body = titles.joined(separator: " · ")
        }

        content.categoryIdentifier = Self.categoryID
        // F-052: while respecting Focus, deliver passively with no sound so the notification
        // lands in Notification Center without breaking through or interrupting.
        content.interruptionLevel = silent ? .passive : .timeSensitive
        content.sound = silent ? nil : .default
        content.userInfo = ["groupID": group.id]

        let requestID = "meeting-\(group.id)"
        groupsByRequestID[requestID] = group

        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner + play sound even when the app is frontmost.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requestID = response.notification.request.identifier
        let actionID = response.actionIdentifier
        // Delegate callbacks arrive off the main actor; hop back on (we are always on the main queue
        // for UN callbacks) to touch main-actor state.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.route(actionID: actionID, requestID: requestID)
            }
            completionHandler()
        }
    }

    private func route(actionID: String, requestID: String) {
        guard let group = groupsByRequestID[requestID] else { return }

        switch actionID {
        case ActionID.join:
            if let event = group.events.first { scheduler?.join(event) }
        case ActionID.snooze1:
            scheduler?.snooze(group, by: .one)
        case ActionID.snooze5:
            scheduler?.snooze(group, by: .five)
        case ActionID.already:
            if let event = group.events.first { scheduler?.markAlreadyInCall(event) }
        default:
            break // includes UNNotificationDismissActionIdentifier / default tap
        }

        groupsByRequestID[requestID] = nil
    }

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
}
