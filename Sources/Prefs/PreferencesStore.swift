// OWNER: Prefs module — ObservableObject that loads/persists Preferences JSON.
// All other modules read Preferences through this store; only Prefs writes it.
import Foundation
import Combine
import Core

public final class PreferencesStore: ObservableObject {
    @Published public private(set) var preferences: Preferences = .default

    private var saveWorkItem: DispatchWorkItem?

    public init() {}

    public func load() {
        guard
            let data = try? Data(contentsOf: AppPaths.preferencesURL),
            let decoded = try? JSONDecoder.meetingAlert.decode(Preferences.self, from: data)
        else { return }
        preferences = decoded
    }

    public func save() {
        saveWorkItem?.cancel()
        let snapshot = preferences
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.meetingAlert.encode(snapshot) else { return }
            try? AppPaths.ensureAppSupportDirectory()
            try? data.write(to: AppPaths.preferencesURL, options: .atomic)
        }
        saveWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Mutate + persist in one step (used by PreferencesView / FocusFilter).
    public func update(_ mutate: (inout Preferences) -> Void) {
        var copy = preferences
        mutate(&copy)
        preferences = copy
        save()
    }
}
