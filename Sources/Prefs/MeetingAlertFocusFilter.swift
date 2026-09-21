// OWNER: Prefs module — registers this app as a Focus filter so users can configure
// alert suppression per Focus mode in System Settings → Focus.
// Actual suppression logic lives in Scheduler (reads Preferences.respectFocus).
import AppIntents

public struct MeetingAlertFocusFilter: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "Meeting Alert"
    public static let description = IntentDescription(
        "Configura se alertas de reunião são suprimidos quando este Foco está ativo."
    )

    // Required by InstanceDisplayRepresentable — shown in Focus settings UI.
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Meeting Alert — filtro de foco")
    }

    public init() {}

    public func perform() async throws -> some IntentResult {
        // Actual suppression is driven by Preferences.respectFocus read in the Scheduler.
        .result()
    }
}
