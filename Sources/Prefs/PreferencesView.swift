// OWNER: Prefs module — SwiftUI preferences window + local view model + NSWindowController.
// Uses @ObservedObject (Combine) instead of @State — @State's SwiftUIMacros plugin is absent
// in the SPM command-line toolchain (same workaround as MenuBar module).
// Listens to Notification.Name("MenuBar.openPreferences") without importing MenuBar.
import SwiftUI
import AppKit
import AVFoundation
import Core

// MARK: - Cross-module notifications (Prefs → App composition root)

/// Notifications the Prefs module posts for the App composition root to act on.
public enum PreferencesEvents {
    /// Posted right after a non-empty OAuth client ID is saved. The App layer responds by
    /// switching to real mode (purge demo events, start sync) and opening the OAuth flow.
    public static let clientIDSavedNotification = Notification.Name("Prefs.clientIDSaved")
    /// F-058: userInfo key on `clientIDSavedNotification` carrying a freshly-entered client SECRET
    /// (in-memory only). The App layer writes it to the Keychain via `GoogleAuth.saveClientSecret`.
    /// Absent when the user left the secret field blank (= keep the stored one).
    public static let clientSecretKey = "clientSecret"
    /// F-063: "Testar alerta" — the App layer responds by firing the real T-1 overlay with a
    /// synthetic test event (`AlertScheduler.fireTestAlert()`).
    public static let testAlertNotification = Notification.Name("Prefs.testAlert")
}

// MARK: - ViewModel

/// Local editing state. All fields are @Published because @State is unavailable in this toolchain.
final class PreferencesViewModel: ObservableObject {
    enum SoundMode: String, CaseIterable { case system = "Sistema", file = "Arquivo" }

    @Published var leadNotify: Int
    @Published var leadOverlay: Int
    @Published var soundMode: SoundMode
    @Published var systemSoundName: String
    @Published var soundFileURL: URL?
    @Published var syncIntervalMinutes: Int
    @Published var respectFocus: Bool
    @Published var oauthClientID: String
    // F-057/F-058: Google Desktop-app client SECRET — required by Google's token endpoint even with
    // PKCE. Held only transiently here; persisted to the KEYCHAIN by the App layer, never to
    // UserDefaults. The field starts blank; `hasStoredSecret` tells the UI one is already saved.
    @Published var oauthClientSecret: String = ""
    @Published var hasStoredSecret: Bool
    // F-065: override — use the user's OWN OAuth client instead of the one embedded in the build.
    @Published var useOwnClient: Bool
    // F-056: last OAuth sign-in failure surfaced from the Auth layer, so Diego sees the EXACT
    // error + the authorize URL (client_id truncated) instead of guessing.
    @Published var lastAuthError: String?
    @Published var lastAuthURL: String?

    let store: PreferencesStore

    // F-056: observers for the Auth diagnostics notifications (raw names — no Auth import, matching
    // this module's existing cross-module notification pattern).
    private var authFailObserver: NSObjectProtocol?
    private var authOKObserver: NSObjectProtocol?

    init(store: PreferencesStore) {
        self.store = store
        let p = store.preferences
        leadNotify = p.leadMinutes[.notify] ?? 5
        leadOverlay = p.leadMinutes[.overlay] ?? 1
        syncIntervalMinutes = max(1, Int(p.syncInterval / 60))
        respectFocus = p.respectFocus
        oauthClientID = UserDefaults.standard.string(forKey: "MeetingAlertOAuthClientID") ?? ""
        // F-058: never read the secret back into the UI; only whether one is stored (non-secret flag).
        hasStoredSecret = UserDefaults.standard.bool(forKey: "MeetingAlertHasClientSecret")
        useOwnClient = UserDefaults.standard.bool(forKey: OAuthClientConfig.useOwnClientDefaultsKey)
        // Show a failure that happened before this window was opened.
        lastAuthError = UserDefaults.standard.string(forKey: "MeetingAlertLastAuthError")
        lastAuthURL   = UserDefaults.standard.string(forKey: "MeetingAlertLastAuthURL")
        switch p.sound {
        case .system(let name):
            soundMode = .system
            systemSoundName = name
            soundFileURL = nil
        case .file(let url):
            soundMode = .file
            systemSoundName = "Ping"
            soundFileURL = url
        }
        authFailObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("Auth.signInFailed"), object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.lastAuthError = note.userInfo?["message"] as? String
                self?.lastAuthURL   = note.userInfo?["url"] as? String
            }
        }
        authOKObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("Auth.signInSucceeded"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastAuthError = nil
                self?.lastAuthURL   = nil
            }
        }
    }

    deinit {
        if let authFailObserver { NotificationCenter.default.removeObserver(authFailObserver) }
        if let authOKObserver { NotificationCenter.default.removeObserver(authOKObserver) }
    }

    func commit() {
        store.update { p in
            p.leadMinutes[.notify] = leadNotify
            p.leadMinutes[.overlay] = leadOverlay
            p.syncInterval = TimeInterval(syncIntervalMinutes * 60)
            p.respectFocus = respectFocus
            switch soundMode {
            case .system:
                p.sound = .system(systemSoundName)
            case .file:
                if let url = soundFileURL { p.sound = .file(url) }
            }
        }
        let previousID = (UserDefaults.standard.string(forKey: "MeetingAlertOAuthClientID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // F-065: persist the override toggle first so the resolver below sees the new value.
        let previousUseOwn = UserDefaults.standard.bool(forKey: OAuthClientConfig.useOwnClientDefaultsKey)
        UserDefaults.standard.set(useOwnClient, forKey: OAuthClientConfig.useOwnClientDefaultsKey)
        // F-055: trim newlines too — a pasted client ID often carries a trailing "\n", which Google
        // rejects as `invalid_client`. Also normalize the field so the UI shows the clean value.
        let id = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        oauthClientID = id
        UserDefaults.standard.set(id, forKey: "MeetingAlertOAuthClientID")   // client_id is public

        // F-058: a freshly typed secret is handed to the App layer IN MEMORY (userInfo) → Keychain;
        // an empty field means "keep the stored secret". The secret NEVER touches UserDefaults.
        let secret = oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretProvided = !secret.isEmpty

        // F-065: (re)enter real mode when ANY of id / secret / override changed AND some client is
        // now configured (embedded or user). isConfigured covers the embedded-only case where `id`
        // is empty but the app still has a usable client.
        let changed = id != previousID || secretProvided || useOwnClient != previousUseOwn
        if OAuthClientConfig.isConfigured && changed {
            var info: [AnyHashable: Any] = [:]
            if secretProvided { info[PreferencesEvents.clientSecretKey] = secret }
            NotificationCenter.default.post(
                name: PreferencesEvents.clientIDSavedNotification,
                object: nil,
                userInfo: info.isEmpty ? nil : info
            )
        }
        // Clear the transient secret from the field/memory once handed off; reflect that one is set.
        if secretProvided {
            oauthClientSecret = ""
            hasStoredSecret = true
        }
    }

    /// F-063: ask the App layer to fire the real overlay with a synthetic test event.
    func fireTestAlert() {
        NotificationCenter.default.post(name: PreferencesEvents.testAlertNotification, object: nil)
    }

    func pauseForOneHour() {
        store.update { $0.pauseUntil = Date().addingTimeInterval(3600) }
    }

    func unpause() {
        store.update { $0.pauseUntil = nil }
    }

    // F-053: a calendar is enabled unless its id is in the persisted disabled-set. The primary
    // calendar is always enabled and never written to the set (non-deselectable in the UI).
    func isCalendarEnabled(_ calendar: CalendarInfo) -> Bool {
        if calendar.isPrimary { return true }
        return !store.preferences.disabledCalendarIDs.contains(calendar.id)
    }

    // Applied immediately (not staged behind "Aplicar") so the next sync poll picks it up.
    func setCalendar(_ calendar: CalendarInfo, enabled: Bool) {
        guard !calendar.isPrimary else { return }   // primary is non-deselectable
        store.update { prefs in
            if enabled { prefs.disabledCalendarIDs.remove(calendar.id) }
            else       { prefs.disabledCalendarIDs.insert(calendar.id) }
        }
    }

    func pickSoundFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Escolher arquivo de áudio"
        if panel.runModal() == .OK, let url = panel.url {
            soundFileURL = url
            soundMode = .file
        }
    }

    // F-064: preview players — kept alive as stored properties so ARC does not cut playback short.
    private var previewPlayer: AVAudioPlayer?
    private var previewNSSound: NSSound?

    /// GROUP 4: preview the currently-selected sound at the configured volume (independent of the
    /// system volume via AVAudioPlayer.volume). Uses the SAME resolution rule as the real player.
    func previewSound() {
        previewPlayer?.stop(); previewPlayer = nil
        previewNSSound?.stop(); previewNSSound = nil

        let vol = Float(min(1.0, max(0.0, store.preferences.overlayOptions.volume)))
        let url: URL?
        switch soundMode {
        case .system:
            let c = URL(fileURLWithPath: "/System/Library/Sounds/\(systemSoundName).aiff")
            url = FileManager.default.fileExists(atPath: c.path) ? c : nil
        case .file:
            url = soundFileURL
        }
        if let url, let p = try? AVAudioPlayer(contentsOf: url) {
            p.volume = vol
            previewPlayer = p
            p.play()
        } else {
            let s = NSSound(named: NSSound.Name(systemSoundName)) ?? NSSound(named: NSSound.Name("Ping"))
            s?.volume = vol
            previewNSSound = s
            s?.play()
        }
    }

    /// F-064: "Restaurar padrão" — reset ALL overlay options to their defaults (which reproduce the
    /// original look). Applied immediately, so an open test overlay updates live.
    func restoreOverlayDefaults() {
        store.update { $0.overlayOptions = .default }
    }
}

// MARK: - SwiftUI View

struct PreferencesView: View {
    @ObservedObject var model: PreferencesViewModel
    @ObservedObject var store: PreferencesStore
    @ObservedObject var catalog: CalendarCatalog       // F-053: discovered calendars for the picker
    @ObservedObject var syncStatus: SyncStatusCenter   // F-057: last-sync status surface
    @ObservedObject var authStatus: AuthStatusCenter   // F-059: connection/token status surface

    private var isPaused: Bool {
        if let until = store.preferences.pauseUntil { return until > Date() }
        return false
    }

    private static let systemSounds = [
        "Ping", "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Pop", "Purr", "Sosumi",
        "Submarine", "Tink"
    ]

    /// F-057: "há X min · N calendário(s)" or "nunca" for the last successful sync.
    static func lastSyncText(_ snap: SyncStatusSnapshot) -> String {
        guard let last = snap.lastSuccess else { return "nunca" }
        let diff = Date().timeIntervalSince(last)
        let when: String
        if diff < 60 { when = "há menos de 1 min" }
        else if diff < 3600 { when = "há \(Int(diff / 60)) min" }
        else { let h = Int(diff / 3600); when = h == 1 ? "há 1h" : "há \(h)h" }
        return "\(when) · \(snap.calendarCount) calendário(s)"
    }

    /// F-059: one-line connection status — "Conectado como <email> · token válido até HH:MM ·
    /// refresh OK/erro". Returns nil when there is nothing to show yet (never signed in).
    static func authStatusText(_ snap: AuthStatusSnapshot) -> String? {
        guard snap.hasRefreshToken || snap.connectedEmail != nil || snap.tokenValidUntil != nil
        else { return nil }
        var parts: [String] = []
        parts.append(snap.connectedEmail.map { "Conectado como \($0)" } ?? "Conectado")
        if let until = snap.tokenValidUntil {
            parts.append("token válido até \(until.formatted(date: .omitted, time: .shortened))")
        }
        switch snap.lastRefreshOK {
        case .some(true):  parts.append("refresh OK")
        case .some(false): parts.append("refresh erro")
        case .none:        break
        }
        return parts.joined(separator: " · ")
    }

    /// F-053: parse a Google `backgroundColor` hex ("#rrggbb") into a swatch color.
    /// Falls back to a neutral gray for missing/malformed values.
    static func color(forHex hex: String?) -> Color {
        guard var s = hex else { return .gray }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return .gray }
        return Color(
            .sRGB,
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue:  Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }

    // MARK: - F-064 overlay-option bindings (applied IMMEDIATELY, so an open test overlay
    // re-applies live — the composition root's Preferences observer calls presenter.reapply()).

    private func opt<T>(_ kp: WritableKeyPath<OverlayOptions, T>) -> Binding<T> {
        Binding(
            get: { store.preferences.overlayOptions[keyPath: kp] },
            set: { newValue in store.update { $0.overlayOptions[keyPath: kp] = newValue } }
        )
    }

    private func colorOpt(_ kp: WritableKeyPath<OverlayOptions, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(rgba: store.preferences.overlayOptions[keyPath: kp]) },
            set: { newValue in store.update { $0.overlayOptions[keyPath: kp] = RGBAColor(color: newValue) } }
        )
    }

    private func snoozeSlot(_ index: Int) -> Binding<Int> {
        Binding(
            get: {
                let s = store.preferences.overlayOptions.normalizedSnoozeMinutes
                return s[index]
            },
            set: { newValue in
                store.update {
                    var s = $0.overlayOptions.normalizedSnoozeMinutes
                    s[index] = min(60, max(1, newValue))
                    $0.overlayOptions.snoozeMinutes = s
                }
            }
        )
    }

    private var useSystemAccent: Binding<Bool> {
        Binding(
            get: { store.preferences.overlayOptions.accentColor == nil },
            set: { on in
                store.update {
                    $0.overlayOptions.accentColor = on ? nil : RGBAColor(red: 0, green: 0.48, blue: 1)
                }
            }
        )
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: store.preferences.overlayOptions.accentColor ?? RGBAColor(red: 0, green: 0.48, blue: 1)) },
            set: { newValue in store.update { $0.overlayOptions.accentColor = RGBAColor(color: newValue) } }
        )
    }

    // MARK: - F-064 "Tela de aviso" sections (extracted to keep the type-checker happy)

    @ViewBuilder private var appearanceSection: some View {
        Section {
            ColorPicker("Cor de fundo", selection: colorOpt(\.backgroundColor), supportsOpacity: false)
            let opacity = opt(\.backgroundOpacity)
            VStack(alignment: .leading) {
                Text("Opacidade: \(Int(opacity.wrappedValue * 100))%")
                Slider(value: opacity, in: 0.30...1.0)
            }
            Picker("Tema", selection: opt(\.theme)) {
                Text("Claro").tag(OverlayTheme.light)
                Text("Escuro").tag(OverlayTheme.dark)
                Text("Automático").tag(OverlayTheme.automatic)
            }
            Picker("Tamanho do texto", selection: opt(\.textSize)) {
                Text("Pequeno").tag(OverlayTextSize.small)
                Text("Médio").tag(OverlayTextSize.medium)
                Text("Grande").tag(OverlayTextSize.large)
            }
            Toggle("Botão Entrar: cor do sistema", isOn: useSystemAccent)
            if !useSystemAccent.wrappedValue {
                ColorPicker("Cor do botão Entrar", selection: accentColorBinding, supportsOpacity: false)
            }
        } header: {
            HStack {
                Text("Tela de aviso — Aparência")
                Spacer()
                Button { model.fireTestAlert() } label: {
                    Label("Testar alerta", systemImage: "bell.badge")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var contentSection: some View {
        Section("Tela de aviso — Conteúdo exibido") {
            Toggle("Participantes (contagem + iniciais)", isOn: opt(\.showParticipants))
            Toggle("Descrição", isOn: opt(\.showDescription))
            if opt(\.showDescription).wrappedValue {
                Stepper("Linhas da descrição: \(opt(\.descriptionLineLimit).wrappedValue)",
                        value: opt(\.descriptionLineLimit), in: 1...10)
            }
            Toggle("Local", isOn: opt(\.showLocation))
            Toggle("Nome do calendário (com cor)", isOn: opt(\.showCalendarName))
            Toggle("Contagem regressiva", isOn: opt(\.showCountdown))
            Toggle("Link da chamada (como texto)", isOn: opt(\.showCallLink))
        }
    }

    @ViewBuilder private var modeSection: some View {
        Section("Tela de aviso — Modo e posição") {
            Picker("Modo", selection: opt(\.mode)) {
                Text("Tela cheia").tag(OverlayMode.fullscreen)
                Text("Janela flutuante").tag(OverlayMode.floating)
            }
            if opt(\.mode).wrappedValue == .floating {
                Picker("Posição", selection: opt(\.floatingCorner)) {
                    Text("Superior esquerdo").tag(OverlayCorner.topLeft)
                    Text("Superior direito").tag(OverlayCorner.topRight)
                    Text("Inferior esquerdo").tag(OverlayCorner.bottomLeft)
                    Text("Inferior direito").tag(OverlayCorner.bottomRight)
                    Text("Centro").tag(OverlayCorner.center)
                }
                Stepper("Margem: \(Int(opt(\.floatingMargin).wrappedValue)) pt",
                        value: opt(\.floatingMargin), in: 0...200, step: 4)
            }
            Picker("Monitores", selection: opt(\.monitors)) {
                Text("Todos").tag(OverlayMonitors.all)
                Text("Apenas principal").tag(OverlayMonitors.primary)
                Text("Onde está o mouse").tag(OverlayMonitors.mouse)
            }
            Stepper(opt(\.autoCloseSeconds).wrappedValue == 0
                    ? "Fechar automaticamente: nunca"
                    : "Fechar automaticamente: \(opt(\.autoCloseSeconds).wrappedValue)s",
                    value: opt(\.autoCloseSeconds), in: 0...600, step: 5)
        }
    }

    @ViewBuilder private var snoozeSection: some View {
        Section {
            Stepper("Adiar 1: \(snoozeSlot(0).wrappedValue) min", value: snoozeSlot(0), in: 1...60)
            Stepper("Adiar 2: \(snoozeSlot(1).wrappedValue) min", value: snoozeSlot(1), in: 1...60)
            Stepper("Adiar 3: \(snoozeSlot(2).wrappedValue) min", value: snoozeSlot(2), in: 1...60)
        } header: {
            Text("Tela de aviso — Adiar (snooze)")
        } footer: {
            Text("Os atalhos de teclado seguem os valores (só valores de 1 a 9 dígito único têm atalho; outros são só clique/legenda).")
                .font(.caption2)
        }
    }

    var body: some View {
        Form {
            // Lead times
            Section("Tempo de antecedência") {
                Stepper(
                    "Notificação (T-\(model.leadNotify)): \(model.leadNotify) min",
                    value: $model.leadNotify, in: 1...30
                )
                Stepper(
                    "Overlay (T-\(model.leadOverlay)): \(model.leadOverlay) min",
                    value: $model.leadOverlay, in: 1...15
                )
            }

            // Sound
            Section("Som de alerta") {
                Picker("Fonte", selection: $model.soundMode) {
                    ForEach(PreferencesViewModel.SoundMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                if model.soundMode == .system {
                    Picker("Som", selection: $model.systemSoundName) {
                        ForEach(Self.systemSounds, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } else {
                    HStack {
                        Text(model.soundFileURL?.lastPathComponent ?? "Nenhum arquivo selecionado")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Escolher…") { model.pickSoundFile() }
                    }
                }

                // F-064 (GROUP 4): volume independente do sistema + repetição + preview.
                let volume = opt(\.volume)
                VStack(alignment: .leading) {
                    Text("Volume: \(Int(volume.wrappedValue * 100))%")
                    Slider(value: volume, in: 0.0...1.0)
                }
                Stepper(opt(\.soundRepeatSeconds).wrappedValue == 0
                        ? "Repetir som: uma vez"
                        : "Repetir som: a cada \(opt(\.soundRepeatSeconds).wrappedValue)s",
                        value: opt(\.soundRepeatSeconds), in: 0...60, step: 1)
                Button { model.previewSound() } label: {
                    Label("Pré-ouvir som", systemImage: "play.circle")
                }

                // F-063: fire the REAL full-screen overlay (all monitors, configured sound,
                // countdown, sample link) with a synthetic test event — same code path as a
                // real alert, so it validates true behavior. Touches no real events/history.
                HStack {
                    Button {
                        model.fireTestAlert()
                    } label: {
                        Label("Testar alerta", systemImage: "bell.badge")
                    }
                    Spacer()
                    Text("Dispara o overlay real (Esc para fechar)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // F-064: the four customization groups for the alert overlay. Every control writes the
            // store IMMEDIATELY (not staged behind "Aplicar"), so an open test overlay re-applies live.
            appearanceSection
            contentSection
            modeSection
            snoozeSection

            Section {
                Button(role: .destructive) {
                    model.restoreOverlayDefaults()
                } label: {
                    Label("Restaurar padrão da tela de aviso", systemImage: "arrow.uturn.backward")
                }
            }

            // Calendars — F-053: one checkbox per calendar, all enabled by default, primary
            // always enabled and non-deselectable. Only the unchecked ids are persisted.
            Section("Calendários") {
                if catalog.calendars.isEmpty {
                    Text("Nenhum calendário carregado ainda. Faça login e aguarde a primeira sincronização.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(catalog.calendars) { cal in
                        Toggle(isOn: Binding(
                            get: { model.isCalendarEnabled(cal) },
                            set: { model.setCalendar(cal, enabled: $0) }
                        )) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Self.color(forHex: cal.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(cal.summary)
                                    .lineLimit(1)
                                if cal.isPrimary {
                                    Text("principal")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(cal.isPrimary)   // primary is always on, non-deselectable
                    }
                }
            }

            // Sync
            Section("Sincronização") {
                Stepper(
                    "Intervalo: \(model.syncIntervalMinutes) min",
                    value: $model.syncIntervalMinutes, in: 1...60
                )

                // F-057: last-sync status — hora, nº de eventos e o erro EXATO se houver, para
                // nunca mais ficar cego diante de "login OK mas zero eventos".
                let snap = syncStatus.snapshot
                HStack {
                    Text("Última sincronização")
                    Spacer()
                    Text(Self.lastSyncText(snap))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                HStack {
                    Text("Eventos na janela (hoje+amanhã)")
                    Spacer()
                    Text("\(snap.eventCount)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                if let err = snap.lastError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Falha na última sincronização", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let urlStr = snap.enableAPIURL, let url = URL(string: urlStr) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Habilitar a Google Calendar API", systemImage: "arrow.up.right.square")
                            }
                            .controlSize(.small)
                            Text("Após habilitar, aguarde ~1 min e clique em \"Conectar Google\" ou espere o próximo ciclo.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Focus
            Section("Foco / Não Perturbe") {
                // OFF (default) = respect Focus — overlays are downgraded to silent notification.
                // ON = ignore Focus — overlay fires even while a Focus mode is active.
                Toggle(
                    "Ignorar Focus",
                    isOn: Binding(
                        get: { !model.respectFocus },
                        set: { model.respectFocus = !$0 }
                    )
                )
            }

            // Pause
            Section("Pausar alertas") {
                if isPaused, let until = store.preferences.pauseUntil {
                    HStack {
                        Text("Pausado até \(until.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("Retomar agora") { model.unpause() }
                    }
                } else {
                    Button("Pausar por 1 hora") { model.pauseForOneHour() }
                }
            }

            // OAuth Client ID
            Section("Google OAuth") {
                // F-059: connection/token status — proves the login persisted and that silent
                // refresh is working, so the "logged in again and again" loop is visibly gone.
                if let status = Self.authStatusText(authStatus.snapshot) {
                    Label(status, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // F-065: by default the app uses the OAuth client embedded in the build, so most
                // people never touch this. Flip the toggle to use your OWN Google Cloud client.
                Toggle("Usar meu próprio client OAuth", isOn: $model.useOwnClient)
                    .font(.callout)

                if OAuthClientConfig.hasEmbeddedCredentials && !model.useOwnClient {
                    Label("Este app já vem com um cliente OAuth embutido — não precisa configurar nada. Ative a opção acima só se quiser usar seu próprio projeto do Google Cloud.",
                          systemImage: "shippingbox.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !OAuthClientConfig.hasEmbeddedCredentials && !model.useOwnClient {
                    Label("Este build não tem credenciais OAuth embutidas. Ative \"Usar meu próprio client OAuth\" e cole o Client ID + Secret de um cliente \"App para computador\", ou veja o README.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only relevant when overriding with your own client (or when nothing is embedded).
                if model.useOwnClient || !OAuthClientConfig.hasEmbeddedCredentials {
                    TextField("Client ID (cole aqui)", text: $model.oauthClientID)
                        .font(.system(.caption, design: .monospaced))
                    SecureField(model.hasStoredSecret ? "Client Secret (salvo — deixe em branco para manter)"
                                                        : "Client Secret (cole aqui)",
                                text: $model.oauthClientSecret)
                        .font(.system(.caption, design: .monospaced))
                    if model.hasStoredSecret {
                        Label("Client Secret salvo (credentials.json, 0600)", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text("Use um cliente OAuth do tipo \"App para computador\" (Desktop app) e cole o Client ID E o Client Secret. O Google EXIGE o Client Secret na troca de código→token (mesmo com PKCE) — sem ele a conexão falha com HTTP 400. Clientes \"Aplicativo da Web\" são bloqueados no fluxo loopback. O secret é guardado em arquivo protegido (0600), nunca em texto plano no repositório.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // F-056: surface the last OAuth failure (exact error + the authorize URL we opened,
                // client_id truncated) so Diego doesn't have to guess what Google rejected.
                if let err = model.lastAuthError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Última falha de autorização", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = model.lastAuthURL {
                            Text("URL usada:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(url)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500, height: 580)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Aplicar") { model.commit() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .navigationTitle("Preferências")
    }
}

// MARK: - Window Controller

/// Listens to MenuBarController.openPreferencesNotification (raw name, no import of MenuBar)
/// and shows the preferences window. Call `setup(store:)` once from AppDelegate.
@MainActor
public final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    // Strong ref keeps the controller alive while the window is open.
    private static var current: PreferencesWindowController?
    private static var notificationObserver: NSObjectProtocol?
    // MainActor-isolated store binding, so the @Sendable observer block captures only the
    // (Sendable) metatype instead of the non-Sendable PreferencesStore instance.
    private static var boundStore: PreferencesStore?

    private init(store: PreferencesStore) {
        let model = PreferencesViewModel(store: store)
        let view = PreferencesView(model: model, store: store, catalog: CalendarCatalog.shared, syncStatus: SyncStatusCenter.shared, authStatus: AuthStatusCenter.shared)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferências"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Call once from AppDelegate after building the object graph.
    public static func setup(store: PreferencesStore) {
        boundStore = store
        notificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MenuBar.openPreferences"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let store = Self.boundStore else { return }
                Self.open(store: store)
            }
        }
    }

    private static func open(store: PreferencesStore) {
        if let wc = current, let win = wc.window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = PreferencesWindowController(store: store)
        current = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

// MARK: - F-064: RGBAColor ↔ SwiftUI Color (Core stays Foundation-only; conversion lives in Prefs)

extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBAColor {
    /// Extract sRGB components from a SwiftUI Color via NSColor. Falls back to opaque black if the
    /// color cannot be represented in sRGB (e.g. a dynamic/system color that fails conversion).
    init(color: Color) {
        let ns = NSColor(color)
        guard let c = ns.usingColorSpace(.sRGB) else {
            self = .black
            return
        }
        self.init(
            red: Double(c.redComponent),
            green: Double(c.greenComponent),
            blue: Double(c.blueComponent),
            alpha: Double(c.alphaComponent)
        )
    }
}
