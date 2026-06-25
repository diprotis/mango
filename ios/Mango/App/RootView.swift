import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    var body: some View {
        Group {
            if let profile = profiles.first, profile.hasOnboarded {
                MainTabView()
            } else {
                OnboardingFlow()
            }
        }
        .task {
            SeedData.ensureSeeded(in: context)
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
