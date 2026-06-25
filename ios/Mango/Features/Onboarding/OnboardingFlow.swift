import SwiftData
import SwiftUI

/// A short, value-first onboarding that builds the reader's profile (their
/// "library is built from who they are") and sets a gentle daily reminder.
struct OnboardingFlow: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query private var profiles: [UserProfile]

    @State private var step = 0
    @State private var name = ""
    @State private var goals: Set<String> = []
    @State private var interests: Set<String> = []
    @State private var level: ReadingLevel = .focused
    @State private var reminderOn = true
    @State private var reminderTime = Calendar.current.date(
        bySettingHour: 8, minute: 0, second: 0, of: .now
    ) ?? .now

    private let goalOptions = ["Be calmer", "Focus better", "Build habits", "Lead well", "Be happier", "Think clearly"]
    private let interestOptions = ["Stoicism", "Productivity", "Psychology", "Business", "Mindfulness", "Philosophy", "Science", "Health"]
    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step + 1), total: Double(lastStep + 1))
                .tint(Palette.accent)
                .padding(.horizontal, Metrics.padL)
                .padding(.top, Metrics.pad)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.padL) {
                    stepContent
                }
                .padding(Metrics.padL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .mangoBackground()
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: goalsStep
        case 2: interestsStep
        case 3: levelStep
        default: reminderStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🥭").font(.system(size: 64))
            Text("Welcome to Mango")
                .font(Typo.display)
                .foregroundStyle(Palette.textPrimary)
            Text("Turn any book into a guided, game-like journey — read a little, do a little, and watch it stick.")
                .font(.title3)
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("What should we call you?").font(.headline).foregroundStyle(Palette.textPrimary)
                TextField("Your name (optional)", text: $name)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            }
            .padding(.top, 8)
        }
    }

    private var goalsStep: some View {
        stepScaffold(
            title: "What are you here to do?",
            subtitle: "Pick a few. We'll tailor your journeys around these."
        ) {
            chipGrid(goalOptions, selection: $goals)
        }
    }

    private var interestsStep: some View {
        stepScaffold(
            title: "What are you drawn to?",
            subtitle: "We'll suggest reading that fits your taste."
        ) {
            chipGrid(interestOptions, selection: $interests)
        }
    }

    private var levelStep: some View {
        stepScaffold(
            title: "How deep do you want to go?",
            subtitle: "You can change this anytime — start small."
        ) {
            VStack(spacing: 12) {
                ForEach(ReadingLevel.allCases) { option in
                    Button {
                        Haptics.selection()
                        level = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.headline).foregroundStyle(Palette.textPrimary)
                                Text("\(option.subtitle) · \(option.suggestedDailyUnits) lesson\(option.suggestedDailyUnits > 1 ? "s" : "")/day")
                                    .font(.subheadline).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: level == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(level == option ? Palette.accent : Palette.textTertiary)
                                .font(.title3)
                        }
                        .padding(16)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(level == option ? Palette.accent : Palette.border, lineWidth: level == option ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var reminderStep: some View {
        stepScaffold(
            title: "Build the habit",
            subtitle: "A single, gentle nudge a day — no spam, off anytime."
        ) {
            VStack(spacing: 16) {
                Toggle(isOn: $reminderOn) {
                    Label("Daily reminder", systemImage: "bell.badge")
                        .font(.headline)
                        .foregroundStyle(Palette.textPrimary)
                }
                .tint(Palette.accent)

                if reminderOn {
                    DatePicker("When?", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        .tint(Palette.accent)
                }
            }
            .padding(16)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(.mangoSecondary)
                    .frame(width: 110)
            }
            Button(step == lastStep ? "Start reading" : "Continue") {
                Haptics.tap()
                if step == lastStep {
                    finish()
                } else {
                    withAnimation { step += 1 }
                }
            }
            .buttonStyle(.mangoPrimary)
        }
        .padding(Metrics.padL)
        .background(.ultraThinMaterial)
    }

    private func stepScaffold(title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Typo.title).foregroundStyle(Palette.textPrimary)
            Text(subtitle).font(.callout).foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    private func chipGrid(_ options: [String], selection: Binding<Set<String>>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(options, id: \.self) { option in
                let isOn = selection.wrappedValue.contains(option)
                Button {
                    Haptics.selection()
                    if isOn { selection.wrappedValue.remove(option) }
                    else { selection.wrappedValue.insert(option) }
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isOn ? Palette.onAccent : Palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isOn ? Palette.accent : Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isOn ? .clear : Palette.border))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func finish() {
        let profile = profiles.first ?? {
            let created = UserProfile()
            context.insert(created)
            return created
        }()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.goals = Array(goals)
        profile.interests = Array(interests)
        profile.readingLevel = level
        profile.dailyGoalUnits = level.suggestedDailyUnits
        profile.hasOnboarded = true

        if reminderOn {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
            profile.reminderHour = comps.hour
            profile.reminderMinute = comps.minute ?? 0
            app.settings.reminderEnabled = true
            let goalLine = goals.first ?? "grow"
            Task {
                if await app.notifications.requestAuthorization() {
                    await app.notifications.scheduleDailyReminder(
                        hour: comps.hour ?? 8,
                        minute: comps.minute ?? 0,
                        body: "Toward your goal to \(goalLine.lowercased()) — a few minutes with your book?"
                    )
                }
            }
        }
        try? context.save()
    }
}

#Preview {
    OnboardingFlow()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
