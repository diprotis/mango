import Foundation

/// Resolves the active AIService from settings + stored secrets.
enum AIServiceProvider {
    static func make(settings: AppSettings) -> AIService {
        switch settings.aiMode {
        case .mock:
            return MockAIService()
        case .backend:
            return backend(settings) ?? MockAIService()
        case .directClaude:
            return direct() ?? MockAIService()
        case .auto:
            return backend(settings) ?? direct() ?? MockAIService()
        }
    }

    private static func backend(_ settings: AppSettings) -> AIService? {
        guard settings.hasBackend, let url = URL(string: settings.backendBaseURL) else { return nil }
        let client = APIClient(
            baseURL: url,
            deviceUserId: settings.deviceUserId,
            authToken: Keychain.read(.authToken)
        )
        return RemoteAIService(client: client)
    }

    private static func direct() -> AIService? {
        guard let key = Keychain.read(.anthropicKey), !key.isEmpty else { return nil }
        return DirectClaudeAIService(apiKey: key)
    }
}
