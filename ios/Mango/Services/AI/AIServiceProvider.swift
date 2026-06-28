import Foundation

/// Resolves the active AIService from the selected environment.
///
/// Precedence: a configured real backend (personal/beta/prod, Bedrock-backed) →
/// the offline mock. (On-device direct-to-Anthropic generation was removed; the
/// backend is the only real generator.)
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

        return MockAIService()
    }
}
