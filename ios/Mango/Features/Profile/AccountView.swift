import SwiftUI

/// A small account screen: shows the signed-in email (decoded from the id token
/// for display), and offers sign-out and a (stubbed) account deletion.
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Present the signed-out / sign-in screen.
    @State private var showingAuth = false
    @State private var showingDeleteConfirm = false

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
            Button("Delete account", role: .destructive) {
                showingDeleteConfirm = true
            }
        } footer: {
            Text("Deletes your Cognito account and all backend data.")
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

    private func deleteAccount() {
        // TODO(M4): call delete endpoint — DELETE /v1/me removes the Cognito user
        // and cascades backend data deletion (spec 0004). For now, sign out locally.
        auth.signOut()
        app.reloadAIService()
        Haptics.warning()
        dismiss()
    }
}

#Preview {
    NavigationStack { AccountView() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
