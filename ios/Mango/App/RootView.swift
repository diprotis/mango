import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query private var profiles: [UserProfile]

    /// Whether to show the (optional, non-blocking) sign-in prompt.
    @State private var showingAuth = false
    /// Set once the user dismisses or completes the prompt, so we don't re-nag
    /// within a single launch.
    @State private var authPrompted = false

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
            // Best-effort silent refresh of an existing session on launch.
            await app.auth.refreshIfNeeded()
            app.reloadAIService()
            maybePromptForSignIn()
        }
        .sheet(isPresented: $showingAuth) {
            AuthView(onContinueOffline: {})
        }
    }

    /// Gently prompt for sign-in only when a real backend is selected but there's
    /// no valid session. Never blocks Offline/Direct use.
    private func maybePromptForSignIn() {
        guard !authPrompted else { return }
        guard app.settings.apiEnvironment.isReal else { return }
        guard !app.auth.isSignedIn else { return }
        guard app.auth.isConfigured else { return }
        // Only meaningful once onboarding is done.
        guard profiles.first?.hasOnboarded == true else { return }
        authPrompted = true
        showingAuth = true
    }
}

#Preview {
    RootView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
