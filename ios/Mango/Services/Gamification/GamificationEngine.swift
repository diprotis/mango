import Foundation
import SwiftData

struct GamificationOutcome {
    var xpAwarded: Int = 0
    var leveledUpTo: Int?
    var newlyUnlocked: [Achievement] = []
    var usedFreeze: Bool = false
}

/// Applies gamification rules against SwiftData: XP, levels, streaks, the daily
/// goal, and achievement unlocks.
@MainActor
struct GamificationEngine {
    let context: ModelContext
    var now: Date = .now
    var calendar: Calendar = .current

    // MARK: Daily activity

    func todayActivity() -> ActivityDay {
        let start = calendar.startOfDay(for: now)
        let predicate = #Predicate<ActivityDay> { $0.day == start }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            return existing
        }
        let day = ActivityDay(day: start)
        context.insert(day)
        return day
    }

    func dailyProgress(goalUnits: Int) -> (done: Int, goal: Int, fraction: Double) {
        let done = todayActivity().lessonsCompleted
        let goal = max(1, goalUnits)
        return (done, goal, min(1, Double(done) / Double(goal)))
    }

    // MARK: Recording

    /// Call after an exercise is graded. Awards XP, advances the streak, and
    /// evaluates achievements.
    @discardableResult
    func recordExercise(_ exercise: Exercise, awardedXP: Int, profile: UserProfile) -> GamificationOutcome {
        var outcome = GamificationOutcome(xpAwarded: awardedXP)
        let levelBefore = profile.level

        profile.totalXP += awardedXP
        let today = todayActivity()
        today.xpEarned += awardedXP
        today.exercisesCompleted += 1

        outcome.usedFreeze = advanceStreak(profile: profile)

        var unlocked: [String] = [AchievementCatalog.firstStep]
        switch exercise.kind {
        case .reading: break  // reading is its own first-class step; no kind-specific badge yet
        case .quiz: unlocked.append(AchievementCatalog.firstQuiz)
        case .reflection: unlocked.append(AchievementCatalog.firstReflection)
        case .application: unlocked.append(AchievementCatalog.appliedIt)
        }
        if calendar.component(.hour, from: now) >= 22 { unlocked.append(AchievementCatalog.nightOwl) }
        if profile.level >= 5 { unlocked.append(AchievementCatalog.level5) }
        if profile.currentStreak >= 7 { unlocked.append(AchievementCatalog.weekOne) }
        if outcome.usedFreeze { unlocked.append(AchievementCatalog.comeback) }

        outcome.newlyUnlocked = unlocked.compactMap { unlock($0) }
        if profile.level > levelBefore { outcome.leveledUpTo = profile.level }
        return outcome
    }

    /// Call when every exercise in a lesson is complete.
    @discardableResult
    func recordLessonCompletion(_ lesson: Lesson, profile: UserProfile) -> [Achievement] {
        if lesson.completedAt == nil { lesson.completedAt = now }
        let today = todayActivity()
        today.lessonsCompleted += 1

        var unlocked = [AchievementCatalog.finishedLesson]
        if today.lessonsCompleted >= 3 { unlocked.append(AchievementCatalog.deepDiver) }
        return unlocked.compactMap { unlock($0) }
    }

    // MARK: Internals

    @discardableResult
    private func advanceStreak(profile: UserProfile) -> Bool {
        let state = StreakState(
            current: profile.currentStreak,
            longest: profile.longestStreak,
            lastActiveDay: profile.lastActiveDay,
            freezes: profile.freezesAvailable
        )
        let result = StreakCalculator.register(state, on: now, calendar: calendar)
        profile.currentStreak = result.state.current
        profile.longestStreak = result.state.longest
        profile.lastActiveDay = result.state.lastActiveDay
        profile.freezesAvailable = result.state.freezes
        return result.usedFreeze
    }

    @discardableResult
    func unlock(_ key: String) -> Achievement? {
        let predicate = #Predicate<Achievement> { $0.key == key }
        guard let achievement = try? context.fetch(FetchDescriptor(predicate: predicate)).first,
              !achievement.isUnlocked
        else { return nil }
        achievement.unlockedAt = now
        return achievement
    }
}
