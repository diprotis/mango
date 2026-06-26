import SwiftData
import SwiftUI

/// A small account screen: shows the signed-in email (decoded from the id token
/// for display), and offers sign-out and account deletion.
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [UserProfile]

    /// Present the signed-out / sign-in screen.
    @State private var showingAuth = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false

    private var auth: AuthService { app.auth }

    var body: some View {
        Form {
            if auth.isSignedIn {
                signedInSections
            } else {
                signedOutSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAuth) {
            AuthView()
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account and all backend data. This can't be undone.")
        }
    }

    @ViewBuilder
    private var signedInSections: some View {
        Section("Signed in") {
            LabeledContent("Email", value: auth.session?.email ?? "Signed in")
                .foregroundStyle(Palette.textPrimary)
        }

        Section {
            Button("Sign out") { signOut() }
                .foregroundStyle(Palette.textPrimary)
        } footer: {
            Text("Signing out clears your session on this device. Mango keeps working offline.")
        }

        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                if isDeleting {
                    HStack { ProgressView(); Text("Deleting…") }
                } else {
                    Text("Delete account")
                }
            }
            .disabled(isDeleting)
        } footer: {
            Text("Deletes your Cognito account and all backend data, and resets this device.")
        }
    }

    @ViewBuilder
    private var signedOutSection: some View {
        Section {
            Button("Sign in / Create account") { showingAuth = true }
                .foregroundStyle(Palette.accent)
        } footer: {
            Text("You're using Mango offline. Sign in to sync your progress and use the live backend.")
        }
    }

    private func signOut() {
        auth.signOut()
        app.reloadAIService()
        Haptics.tap()
    }

    /// Best-effort `DELETE /v1/me` (removes the Cognito user + cascades backend
    /// data, spec 0004), then a hard local reset: sign out, erase every local
    /// `Book`, and flip onboarding off so the app restarts at the welcome flow.
    /// The network call is best-effort — local erasure always proceeds so the
    /// user isn't stuck if the backend is unreachable or unconfigured.
    private func deleteAccount() {
        isDeleting = true
        Task {
            if let client = app.apiClient() {
                try? await client.delete("/v1/me")
            }
            await MainActor.run {
                auth.signOut()
                eraseLocalData()
                app.reloadAIService()
                isDeleting = false
                Haptics.warning()
                dismiss()
            }
        }
    }

    /// Remove all local books and restart onboarding. Keeps the single
    /// `UserProfile` row but clears its progress and onboarding flag so
    /// `RootView` shows the onboarding flow again.
    private func eraseLocalData() {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books { context.delete(book) }
        if let profile = profiles.first {
            profile.hasOnboarded = false
            profile.totalXP = 0
            profile.currentStreak = 0
            profile.longestStreak = 0
            profile.lastActiveDay = nil
        }
        try? context.save()
    }
}

#Preview {
    NavigationStack { AccountView() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
