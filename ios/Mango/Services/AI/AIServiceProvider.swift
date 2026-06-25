import Foundation

/// Resolves the active AIService from the selected environment + stored secrets.
///
/// Precedence: a configured real backend (personal/beta/prod) → an on-device
/// Claude key when offline-and-enabled → the offline mock.
enum AIServiceProvider {
    static func make(settings: AppSettings, auth: AuthService) -> AIService {
        if settings.isRealBackend, let url = settings.effectiveBackendURL {
            let client = APIClient(
                baseURL: url,
                deviceUserId: settings.deviceUserId,
                authToken: auth.session?.idToken
            )
            return RemoteAIService(client: client)
        }

        if settings.useDirectClaudeWhenOffline,
           let key = Keychain.read(.anthropicKey), !key.isEmpty {
            return DirectClaudeAIService(apiKey: key)
        }

        return MockAIService()
    }
}
