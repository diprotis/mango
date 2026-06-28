import SwiftData
import XCTest
@testable import Mango

/// Reading is a first-class activity threaded through the roadmap (ADR-0003):
/// every lesson leads with a `.reading` activity synthesized from its reading
/// summary, completed by self-attestation (no text shown, no grading).
@MainActor
final class ReadingActivityTests: XCTestCase {
    // MARK: ExerciseKind.reading

    func testReadingKindProperties() {
        XCTAssertEqual(ExerciseKind.reading.title, "Read")
        XCTAssertEqual(ExerciseKind.reading.baseXP, 10)
        XCTAssertTrue(ExerciseKind.reading.isSelfAttested)
        XCTAssertFalse(ExerciseKind.quiz.isSelfAttested)
        XCTAssertFalse(ExerciseKind.reflection.isSelfAttested)
        XCTAssertFalse(ExerciseKind.application.isSelfAttested)
    }

    func testReadingKindRoundTrips() {
        XCTAssertEqual(ExerciseKind(rawValue: "reading"), .reading)
    }

    // MARK: RoadmapBuilder synthesis

    private func makeContext() throws -> ModelContext {
        let schema = Schema(MangoSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    /// A generated roadmap should gain a leading reading activity in every lesson,
    /// with the original practice activities preserved and pushed after it.
    func testBuilderThreadsReadingFirstIntoEveryLesson() throws {
        let context = try makeContext()
        let dto = RoadmapDTO(
            title: "T", summary: "S",
            milestones: [
                MilestoneDTO(title: "M1", subtitle: "", lessons: [
                    LessonDTO(title: "L1", readingSummary: "Read about control.", estimatedMinutes: 4, exercises: [
                        ExerciseDTO(kind: "quiz", prompt: "Q?", options: ["a", "b"], answerIndex: 1, xp: 15),
                        ExerciseDTO(kind: "reflection", prompt: "Reflect.", options: nil, answerIndex: nil, xp: 25),
                    ]),
                ]),
            ]
        )
        let book = Book(id: "b1", title: "Book")
        context.insert(book)
        RoadmapBuilder.attach(dto, to: book, in: context)

        let lesson = try XCTUnwrap(book.roadmap?.allLessons.first)
        let activities = lesson.orderedExercises
        XCTAssertEqual(activities.count, 3, "reading + the 2 original activities")
        XCTAssertEqual(activities[0].kind, .reading)
        XCTAssertEqual(activities[0].order, 0)
        XCTAssertEqual(activities[0].xp, 10)
        XCTAssertTrue(activities[0].prompt.contains("L1"), "reading prompt names the section")
        XCTAssertTrue(activities[0].prompt.contains("Read about control."), "carries the reading summary cue")
        // Practice follows, in original order, never first.
        XCTAssertEqual(activities[1].kind, .quiz)
        XCTAssertEqual(activities[2].kind, .reflection)
        XCTAssertEqual(activities[1].order, 1)
        XCTAssertEqual(activities[2].order, 2)
    }

    /// If a model ever emits its own "reading" exercise, the builder must not
    /// produce two reading activities in one lesson.
    func testBuilderDoesNotDoubleUpReading() throws {
        let context = try makeContext()
        let dto = RoadmapDTO(
            title: "T", summary: "S",
            milestones: [
                MilestoneDTO(title: "M1", subtitle: "", lessons: [
                    LessonDTO(title: "L1", readingSummary: "Slice.", estimatedMinutes: 3, exercises: [
                        ExerciseDTO(kind: "reading", prompt: "Read X.", options: nil, answerIndex: nil, xp: 10),
                        ExerciseDTO(kind: "quiz", prompt: "Q?", options: ["a", "b"], answerIndex: 0, xp: 15),
                    ]),
                ]),
            ]
        )
        let book = Book(id: "b2", title: "Book")
        context.insert(book)
        RoadmapBuilder.attach(dto, to: book, in: context)

        let lesson = try XCTUnwrap(book.roadmap?.allLessons.first)
        let readingCount = lesson.orderedExercises.filter { $0.kind == .reading }.count
        XCTAssertEqual(readingCount, 1, "exactly one reading activity per lesson")
        XCTAssertEqual(lesson.orderedExercises.first?.kind, .reading)
    }

    // MARK: Seeded sample demonstrates reading offline

    func testSeededSampleLeadsEveryLessonWithReading() throws {
        let context = try makeContext()
        SeedData.ensureSeeded(in: context)

        let books = try context.fetch(FetchDescriptor<Book>())
        let sample = try XCTUnwrap(books.first { $0.id == "sample-meditations" })
        let lessons = try XCTUnwrap(sample.roadmap?.allLessons)
        XCTAssertFalse(lessons.isEmpty)
        for lesson in lessons {
            XCTAssertEqual(lesson.orderedExercises.first?.kind, .reading,
                           "every sample lesson opens with a reading activity")
        }
    }

    // MARK: Gamification awards reading XP without a kind-specific badge

    func testReadingAwardsXPAndFirstStepOnly() throws {
        let context = try makeContext()
        for def in AchievementCatalog.all {
            context.insert(Achievement(key: def.key, title: def.title, detail: def.detail, symbol: def.symbol))
        }
        let profile = UserProfile()
        context.insert(profile)
        let reading = Exercise(kind: .reading, prompt: "Read it.", xp: 10, order: 0)
        context.insert(reading)

        let engine = GamificationEngine(context: context)
        let outcome = engine.recordExercise(reading, awardedXP: 10, profile: profile)

        XCTAssertEqual(profile.totalXP, 10)
        XCTAssertTrue(outcome.newlyUnlocked.contains { $0.key == AchievementCatalog.firstStep })
        XCTAssertFalse(outcome.newlyUnlocked.contains { $0.key == AchievementCatalog.firstQuiz },
                       "reading must not unlock a quiz/reflection/application badge")
    }
}
