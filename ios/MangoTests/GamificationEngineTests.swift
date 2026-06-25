import SwiftData
import XCTest
@testable import Mango

@MainActor
final class GamificationEngineTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(MangoSchema.models)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for def in AchievementCatalog.all {
            context.insert(Achievement(key: def.key, title: def.title, detail: def.detail, symbol: def.symbol))
        }
        return context
    }

    func testExerciseAwardsXPStartsStreakAndUnlocksFirstStep() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        let exercise = Exercise(kind: .quiz, prompt: "?", xp: 15, order: 0)
        context.insert(exercise)

        let engine = GamificationEngine(context: context)
        let outcome = engine.recordExercise(exercise, awardedXP: 15, profile: profile)

        XCTAssertEqual(profile.totalXP, 15)
        XCTAssertEqual(profile.currentStreak, 1)
        XCTAssertEqual(outcome.xpAwarded, 15)
        XCTAssertTrue(outcome.newlyUnlocked.contains { $0.key == AchievementCatalog.firstStep })
        XCTAssertTrue(outcome.newlyUnlocked.contains { $0.key == AchievementCatalog.firstQuiz })
    }

    func testLessonCompletionCountsTowardDailyGoal() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        let lesson = Lesson(title: "L", readingSummary: "", estimatedMinutes: 5, order: 0)
        context.insert(lesson)

        let engine = GamificationEngine(context: context)
        _ = engine.recordLessonCompletion(lesson, profile: profile)

        let progress = engine.dailyProgress(goalUnits: 2)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.goal, 2)
        XCTAssertNotNil(lesson.completedAt)
    }

    func testAchievementsUnlockOnlyOnce() throws {
        let context = try makeContext()
        let profile = UserProfile()
        context.insert(profile)
        let engine = GamificationEngine(context: context)

        let first = engine.unlock(AchievementCatalog.firstStep)
        let second = engine.unlock(AchievementCatalog.firstStep)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }
}
