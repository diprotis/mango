import SwiftUI

/// A clean, value-first signed-out screen that launches Cognito's Hosted UI.
/// Sign-in is optional: "Continue offline" dismisses and the app keeps working
/// with the on-device Mock backend.
struct AuthView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Called when the user chooses to keep using the app offline.
    var onContinueOffline: () -> Void = {}

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var auth: AuthService { app.auth }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            header
            Spacer()
            actions
        }
        .padding(Metrics.padL)
        .mangoBackground()
        .interactiveDismissDisabled(isSigningIn)
    }

    private var header: some View {
        VStack(spacing: Metrics.pad) {
            Text("🥭").font(.system(size: 72))
            Text("Sign in to sync")
                .font(Typo.display)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("Save your progress, streak, and library across devices — and unlock the live Mango backend. You can always keep reading offline.")
                .font(.title3)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.pad)
        }
    }

    private var actions: some View {
        VStack(spacing: Metrics.gap) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView().tint(Palette.onAccent)
                    }
                    Text(isSigningIn ? "Signing in…" : "Sign in / Create account")
                }
            }
            .buttonStyle(.mangoPrimary(enabled: !isSigningIn))
            .disabled(isSigningIn)

            Button("Continue offline") {
                Haptics.tap()
                onContinueOffline()
                dismiss()
            }
            .buttonStyle(.mangoSecondary)
            .disabled(isSigningIn)
        }
    }

    @MainActor
    private func signIn() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
            app.reloadAIService()
            Haptics.success()
            dismiss()
        } catch AuthError.cancelled {
            // User backed out of the web sheet — no error UI needed.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign-in failed. Please try again."
            Haptics.warning()
        }
    }
}

#Preview {
    AuthView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
