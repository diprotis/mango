import SwiftData
import SwiftUI

@main
struct MangoApp: App {
    @State private var appModel = AppModel()
    private let modelContainer = MangoModelContainer.make()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .tint(Palette.accent)
                .preferredColorScheme(appModel.settings.themePreference.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}
