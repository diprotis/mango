import SwiftUI

/// The app's service container, injected into the SwiftUI environment.
@Observable
final class AppModel {
    let settings: AppSettings
    let auth: AuthService
    private(set) var ai: AIService
    let connectors: ConnectorService
    let notifications: NotificationService

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let auth = AuthService()
        auth.restore()
        self.auth = auth
        self.ai = AIServiceProvider.make(settings: settings, auth: auth)
        self.connectors = ConnectorService(settings: settings)
        self.notifications = NotificationService()
    }

    /// Re-resolve the AI backend after the user changes settings, signs in/out,
    /// or adds a key — so `APIClient` always carries the current id token.
    func reloadAIService() {
        ai = AIServiceProvider.make(settings: settings, auth: auth)
    }

    /// An `APIClient` for the active real environment, carrying the current id
    /// token. `nil` when offline/unconfigured (Mock), so callers can degrade
    /// gracefully. Uses the same resolution as `AIServiceProvider`.
    func apiClient() -> APIClient? {
        guard settings.isRealBackend, let url = settings.effectiveBackendURL else { return nil }
        return APIClient(
            baseURL: url,
            deviceUserId: settings.deviceUserId,
            authToken: auth.session?.idToken
        )
    }

    /// A catalog service bound to the current backend (or a nil client when
    /// offline, in which case its calls throw `APIError.notConfigured`).
    func catalog() -> CatalogService {
        CatalogService(client: apiClient())
    }
}
