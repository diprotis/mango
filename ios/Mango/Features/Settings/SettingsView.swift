import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var showEraseConfirm = false

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section("AI engine") {
                    Picker("Mode", selection: $settings.aiMode) {
                        ForEach(AIMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.aiMode.detail)
                        .font(.caption).foregroundStyle(Palette.textSecondary)

                    if settings.aiMode == .backend || settings.aiMode == .auto {
                        TextField("Backend base URL", text: $settings.backendBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    if settings.aiMode == .directClaude || settings.aiMode == .auto {
                        SecureField("Anthropic API key (sk-ant-…)", text: $apiKey)
                        Button("Save key") { saveKey() }
                        if !keyStatus.isEmpty {
                            Text(keyStatus).font(.caption).foregroundStyle(Palette.success)
                        }
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
            .onAppear { apiKey = Keychain.read(.anthropicKey) ?? "" }
            .onChange(of: settings.aiMode) { app.reloadAIService() }
            .onChange(of: settings.backendBaseURL) { app.reloadAIService() }
            .onChange(of: settings.reminderEnabled) { _, enabled in toggleReminder(enabled) }
            .confirmationDialog("Erase your library?", isPresented: $showEraseConfirm, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) { eraseLibrary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all books and journeys. Your XP, streak, and badges stay.")
            }
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(.anthropicKey)
            keyStatus = "Key removed."
        } else {
            Keychain.save(.anthropicKey, value: trimmed)
            keyStatus = "Key saved to Keychain."
        }
        app.reloadAIService()
        Haptics.success()
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
