import SwiftUI

enum AIMode: String, CaseIterable, Identifiable {
    case auto, mock, backend, directClaude
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .mock: return "Offline (Mock)"
        case .backend: return "Mango Backend"
        case .directClaude: return "Direct Claude API"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Use the backend if set, else a Claude key, else offline."
        case .mock: return "Believable content generated on-device. No network."
        case .backend: return "Calls your deployed AWS backend (recommended for production)."
        case .directClaude: return "Calls Anthropic directly with a key on this device (testing only)."
        }
    }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide preferences, persisted in UserDefaults and observable by SwiftUI.
@Observable
final class AppSettings {
    var aiMode: AIMode { didSet { store.set(aiMode.rawValue, forKey: Keys.aiMode) } }
    var backendBaseURL: String { didSet { store.set(backendBaseURL, forKey: Keys.backend) } }
    var themePreference: ThemePreference { didSet { store.set(themePreference.rawValue, forKey: Keys.theme) } }
    var reminderEnabled: Bool { didSet { store.set(reminderEnabled, forKey: Keys.reminder) } }

    /// Stable per-install id used as a dev fallback for backend requests.
    let deviceUserId: String

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        self.aiMode = AIMode(rawValue: store.string(forKey: Keys.aiMode) ?? "") ?? .auto
        self.backendBaseURL = store.string(forKey: Keys.backend) ?? ""
        self.themePreference = ThemePreference(rawValue: store.string(forKey: Keys.theme) ?? "") ?? .system
        self.reminderEnabled = store.bool(forKey: Keys.reminder)

        if let existing = store.string(forKey: Keys.deviceId) {
            self.deviceUserId = existing
        } else {
            let generated = UUID().uuidString
            store.set(generated, forKey: Keys.deviceId)
            self.deviceUserId = generated
        }
    }

    var hasBackend: Bool {
        guard let url = URL(string: backendBaseURL), url.scheme != nil else { return false }
        return !backendBaseURL.isEmpty
    }

    var hasClaudeKey: Bool { (Keychain.read(.anthropicKey) ?? "").isEmpty == false }

    private enum Keys {
        static let aiMode = "mango.aiMode"
        static let backend = "mango.backendBaseURL"
        static let theme = "mango.theme"
        static let reminder = "mango.reminderEnabled"
        static let deviceId = "mango.deviceUserId"
    }
}
