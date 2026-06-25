import Foundation

/// Which backend the app talks to.
///
/// `mock` is fully offline and is the default, so the app works on first launch
/// with no network or key. Real environments resolve a base URL: **beta/prod**
/// come baked from `AppConfig.plist` (set per build or by CI); **personal** is
/// your own AWS deploy (e.g. `diprotis-dev`) and is entered in Settings.
enum APIEnvironment: String, CaseIterable, Identifiable, Sendable {
    case mock
    case personal
    case beta
    case prod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock: return "Offline (Mock)"
        case .personal: return "Personal (your AWS)"
        case .beta: return "Beta"
        case .prod: return "Prod"
        }
    }

    var detail: String {
        switch self {
        case .mock: return "Generated on-device. No network or key needed."
        case .personal: return "Your own AWS deploy (e.g. diprotis-dev). Enter its URL below."
        case .beta: return "The shared Beta backend."
        case .prod: return "The production backend."
        }
    }

    var isReal: Bool { self != .mock }

    /// The environment a tester lands on when switching the backend on.
    static let defaultReal: APIEnvironment = .prod
}

/// Pure base-URL resolution — unit tested, no I/O.
enum APIEnvironmentResolver {
    static func baseURL(
        for environment: APIEnvironment,
        personal: String,
        beta: String,
        prod: String
    ) -> URL? {
        let raw: String
        switch environment {
        case .mock: return nil
        case .personal: raw = personal
        case .beta: raw = beta
        case .prod: raw = prod
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }
}

/// Reads baked-in environment URLs from the bundled `AppConfig.plist`, so the
/// Beta/Prod endpoints can be set per build (or injected by CI) without code
/// changes. Missing/empty values simply mean "not configured" (app stays offline).
enum AppConfig {
    static var betaBaseURL: String { string("BetaAPIURL") }
    static var prodBaseURL: String { string("ProdAPIURL") }

    private static let values: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any]
        else { return [:] }
        return dict
    }()

    private static func string(_ key: String) -> String {
        (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
