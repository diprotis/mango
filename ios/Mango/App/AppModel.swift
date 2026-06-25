import SwiftUI

/// The app's service container, injected into the SwiftUI environment.
@Observable
final class AppModel {
    let settings: AppSettings
    private(set) var ai: AIService
    let connectors: ConnectorService
    let notifications: NotificationService

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        self.ai = AIServiceProvider.make(settings: settings)
        self.connectors = ConnectorService(settings: settings)
        self.notifications = NotificationService()
    }

    /// Re-resolve the AI backend after the user changes settings or adds a key.
    func reloadAIService() {
        ai = AIServiceProvider.make(settings: settings)
    }
}
