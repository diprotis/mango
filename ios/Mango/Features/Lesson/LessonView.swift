import SwiftData
import SwiftUI

struct LessonView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var profiles: [UserProfile]
    let lesson: Lesson

    @State private var phase: Phase = .exercises
    @State private var index = 0
    @State private var totalXP = 0
    @State private var unlocked: [Achievement] = []
    @State private var leveledTo: Int?
    @State private var celebrate = false
    @State private var lessonWasComplete = false
    @State private var completedAtOpen: Set<Int> = []

    // Reading is now the lesson's first activity (ADR-0003), so the lesson opens
    // straight into the activity sequence — no separate reading phase.
    enum Phase { case exercises, summary }

    private var exercises: [Exercise] { lesson.orderedExercises }
    private var profile: UserProfile? { profiles.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                switch phase {
                case .exercises: exercisePhase
                case .summary: summaryPhase
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            lessonWasComplete = lesson.isCompleted
            completedAtOpen = Set(exercises.indices.filter { exercises[$0].isCompleted })
        }
    }

    @ViewBuilder
    private var exercisePhase: some View {
        if exercises.indices.contains(index) {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                ProgressView(value: Double(index), total: Double(max(1, exercises.count)))
                    .tint(Palette.accent)
                Text("Step \(index + 1) of \(exercises.count)")
                    .font(.caption).foregroundStyle(Palette.textSecondary)

                ExerciseRunnerView(exercise: exercises[index]) { awardedXP in
                    advance(awardedXP: awardedXP)
                }
                .id(index)
            }
        } else {
            // No activities (shouldn't happen — every lesson leads with reading).
            Button("Mark as done") { finishLesson() }
                .buttonStyle(.mangoPrimary)
        }
    }

    private var summaryPhase: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 76))
                .foregroundStyle(Palette.accent)
                .scaleEffect(celebrate ? 1 : 0.5)
                .opacity(celebrate ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: celebrate)

            Text("Lesson complete!").font(Typo.title).foregroundStyle(Palette.textPrimary)
            Text("+\(totalXP) XP").font(.title3.weight(.bold)).foregroundStyle(Palette.xp)

            if let profile {
                HStack(spacing: 10) {
                    StreakPill(days: profile.currentStreak)
                    if let leveledTo {
                        Tag("Level \(leveledTo)!", systemImage: "arrow.up.circle.fill", color: Palette.success)
                    }
                }
            }

            if !unlocked.isEmpty {
                VStack(spacing: 10) {
                    Text("New achievement\(unlocked.count > 1 ? "s" : "")").font(.headline).foregroundStyle(Palette.textPrimary)
                    HStack(spacing: 16) {
                        ForEach(unlocked) { AchievementBadgeView(achievement: $0, size: 56) }
                    }
                }
                .padding(.top, 4)
            }

            Button("Continue") { dismiss() }
                .buttonStyle(.mangoPrimary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .onAppear { celebrate = true }
    }

    private func advance(awardedXP: Int) {
        guard let profile else { return }
        let engine = GamificationEngine(context: context)

        if !completedAtOpen.contains(index) {
            let outcome = engine.recordExercise(exercises[index], awardedXP: awardedXP, profile: profile)
            totalXP += awardedXP
            unlocked += outcome.newlyUnlocked
            if let level = outcome.leveledUpTo { leveledTo = level }

            // The single journey-state dispatch point (0008 #3): completing any
            // activity is the earliest reading signal (nudges notStarted → reading;
            // never touches finished — ADR-0002).
            if let book = lesson.milestone?.roadmap?.book {
                book.journeyState = JourneyStateMachine.apply(.activityCompleted, to: book.journeyState)
            }
        }

        if index + 1 < exercises.count {
            withAnimation { index += 1 }
        } else {
            finishLesson()
        }
        try? context.save()
    }

    private func finishLesson() {
        guard let profile else { return }
        let engine = GamificationEngine(context: context)
        if !lessonWasComplete {
            unlocked += engine.recordLessonCompletion(lesson, profile: profile)
        } else if lesson.completedAt == nil {
            lesson.completedAt = .now
        }
        try? context.save()
        Haptics.success()
        withAnimation { phase = .summary }
    }
}
