import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    @State private var showEraseConfirm = false

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section("Account") {
                    NavigationLink {
                        AccountView()
                    } label: {
                        if app.auth.isSignedIn {
                            LabeledContent("Account", value: app.auth.session?.email ?? "Signed in")
                        } else {
                            Text("Sign in / Create account")
                        }
                    }
                }

                Section("Backend") {
                    Picker("Environment", selection: $settings.apiEnvironment) {
                        ForEach(APIEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.apiEnvironment.detail)
                        .font(.caption).foregroundStyle(Palette.textSecondary)

                    if settings.apiEnvironment == .personal {
                        TextField("Personal API URL (https://…)", text: $settings.personalBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } else if settings.apiEnvironment.isReal {
                        LabeledContent("URL", value: settings.displayBackendURL.isEmpty ? "not set" : settings.displayBackendURL)
                            .font(.caption)
                    }

                    if settings.apiEnvironment.isReal && settings.effectiveBackendURL == nil {
                        Text("No URL for this environment yet. Set BetaAPIURL / ProdAPIURL in AppConfig.plist (or via CI), or use Personal with your own URL.")
                            .font(.caption).foregroundStyle(Palette.warning)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.themePreference) {
                        ForEach(ThemePreference.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Reminders") {
                    Toggle("Daily reminder", isOn: $settings.reminderEnabled)
                }

                Section("Your data") {
                    Button("Restart onboarding") { restartOnboarding() }
                    Button("Erase library", role: .destructive) { showEraseConfirm = true }
                }

                Section {
                    LabeledContent("Version", value: "0.1.0 (beta)")
                } header: {
                    Text("About")
                } footer: {
                    Text("Mango turns reading into a guided, gamified journey. Research preview.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: settings.apiEnvironment) { app.reloadAIService() }
            .onChange(of: settings.personalBaseURL) { app.reloadAIService() }
            .onChange(of: settings.reminderEnabled) { _, enabled in toggleReminder(enabled) }
            .confirmationDialog("Erase your library?", isPresented: $showEraseConfirm, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) { eraseLibrary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all books and journeys. Your XP, streak, and badges stay.")
            }
        }
    }

    private func toggleReminder(_ enabled: Bool) {
        if enabled {
            let profile = profiles.first
            Task {
                if await app.notifications.requestAuthorization() {
                    await app.notifications.scheduleDailyReminder(
                        hour: profile?.reminderHour ?? 8,
                        minute: profile?.reminderMinute ?? 0,
                        body: "A few minutes with your book keeps your streak alive."
                    )
                }
            }
        } else {
            app.notifications.cancelDailyReminder()
        }
    }

    private func restartOnboarding() {
        profiles.first?.hasOnboarded = false
        try? context.save()
        dismiss()
    }

    private func eraseLibrary() {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books { context.delete(book) }
        try? context.save()
        Haptics.warning()
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
