import SwiftUI

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
    /// Selected backend environment. Defaults to `.mock` so first launch is offline.
    var apiEnvironment: APIEnvironment { didSet { store.set(apiEnvironment.rawValue, forKey: Keys.environment) } }
    /// URL for the "personal" environment (your own AWS deploy, e.g. diprotis-dev).
    var personalBaseURL: String { didSet { store.set(personalBaseURL, forKey: Keys.personalURL) } }
    /// When the environment is Offline (Mock) and a Claude key is saved, use it on-device.
    var useDirectClaudeWhenOffline: Bool { didSet { store.set(useDirectClaudeWhenOffline, forKey: Keys.directOffline) } }

    var themePreference: ThemePreference { didSet { store.set(themePreference.rawValue, forKey: Keys.theme) } }
    var reminderEnabled: Bool { didSet { store.set(reminderEnabled, forKey: Keys.reminder) } }

    /// Stable per-install id used as a dev fallback for backend requests.
    let deviceUserId: String

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        self.apiEnvironment = APIEnvironment(rawValue: store.string(forKey: Keys.environment) ?? "") ?? .mock
        self.personalBaseURL = store.string(forKey: Keys.personalURL) ?? ""
        self.useDirectClaudeWhenOffline = store.bool(forKey: Keys.directOffline)
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

    /// Resolved base URL for the selected environment (nil when offline/unconfigured).
    var effectiveBackendURL: URL? {
        APIEnvironmentResolver.baseURL(
            for: apiEnvironment,
            personal: personalBaseURL,
            beta: AppConfig.betaBaseURL,
            prod: AppConfig.prodBaseURL
        )
    }

    /// True when a real environment is selected AND it has a usable URL.
    var isRealBackend: Bool { apiEnvironment.isReal && effectiveBackendURL != nil }

    /// Read-only URL string for display in Settings.
    var displayBackendURL: String { effectiveBackendURL?.absoluteString ?? "" }

    var hasClaudeKey: Bool { (Keychain.read(.anthropicKey) ?? "").isEmpty == false }

    private enum Keys {
        static let environment = "mango.apiEnvironment"
        static let personalURL = "mango.personalBaseURL"
        static let directOffline = "mango.useDirectClaudeWhenOffline"
        static let theme = "mango.theme"
        static let reminder = "mango.reminderEnabled"
        static let deviceId = "mango.deviceUserId"
    }
}
