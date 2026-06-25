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
}
