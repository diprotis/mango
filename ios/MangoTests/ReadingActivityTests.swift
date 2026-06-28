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
            let reading = try XCTUnwrap(lesson.orderedExercises.first)
            XCTAssertEqual(reading.kind, .reading, "every sample lesson opens with a reading activity")
            // Honesty: each seeded anchor quote must literally appear in the book text,
            // so "search for this in your copy" actually works.
            let anchor = try XCTUnwrap(reading.anchorQuote, "sample reading has an anchor quote")
            XCTAssertTrue(sample.fullText.contains(anchor),
                          "anchor quote must be verbatim from the book: \(anchor)")
            XCTAssertNotNil(reading.locator, "sample reading names a locator (Book II/IV/V)")
        }
    }

    // MARK: Builder threads the structured slice (and falls back without it)

    func testBuilderUsesStructuredReadingWhenPresent() throws {
        let context = try makeContext()
        let dto = RoadmapDTO(
            title: "T", summary: "S",
            milestones: [
                MilestoneDTO(title: "M1", subtitle: "", lessons: [
                    LessonDTO(
                        title: "Tiny Habits",
                        readingSummary: "Small gains compound.",
                        estimatedMinutes: 5,
                        reading: ReadingSliceDTO(
                            locator: "Chapter 1: The Power of Tiny Habits",
                            anchorQuote: "The aggregation of marginal gains.",
                            whatToNoticeWhileReading: "Notice how 1% changes compound."
                        ),
                        exercises: [ExerciseDTO(kind: "quiz", prompt: "Q?", options: ["a", "b"], answerIndex: 0, xp: 15)]
                    ),
                ]),
            ]
        )
        let book = Book(id: "b3", title: "Book")
        context.insert(book)
        RoadmapBuilder.attach(dto, to: book, in: context)

        let reading = try XCTUnwrap(book.roadmap?.allLessons.first?.orderedExercises.first)
        XCTAssertEqual(reading.kind, .reading)
        XCTAssertEqual(reading.locator, "Chapter 1: The Power of Tiny Habits")
        XCTAssertEqual(reading.anchorQuote, "The aggregation of marginal gains.")
        XCTAssertEqual(reading.whatToNotice, "Notice how 1% changes compound.")
        XCTAssertTrue(reading.prompt.contains("Chapter 1"), "prompt headline names the locator")
    }

    func testBuilderFallsBackWhenReadingAbsent() throws {
        let context = try makeContext()
        let dto = RoadmapDTO(
            title: "T", summary: "S",
            milestones: [
                MilestoneDTO(title: "M1", subtitle: "", lessons: [
                    // No `reading` (defaults to nil) → fallback path.
                    LessonDTO(title: "L1", readingSummary: "Read about control.", estimatedMinutes: 4, exercises: [
                        ExerciseDTO(kind: "quiz", prompt: "Q?", options: ["a", "b"], answerIndex: 0, xp: 15),
                    ]),
                ]),
            ]
        )
        let book = Book(id: "b4", title: "Book")
        context.insert(book)
        RoadmapBuilder.attach(dto, to: book, in: context)

        let reading = try XCTUnwrap(book.roadmap?.allLessons.first?.orderedExercises.first)
        XCTAssertEqual(reading.kind, .reading)
        XCTAssertNil(reading.locator, "fallback leaves structured fields nil")
        XCTAssertNil(reading.anchorQuote)
        XCTAssertTrue(reading.prompt.contains("Read about control."), "fallback prompt carries the summary")
    }

    // MARK: Lenient decode of the reading slice

    func testRoadmapDecodesWithReadingSlice() throws {
        let json = """
        { "title": "T", "summary": "S", "milestones": [
          { "title": "M", "subtitle": "s", "lessons": [
            { "title": "L", "readingSummary": "r", "estimatedMinutes": 5,
              "reading": { "locator": "Book II", "anchorQuote": "Begin the morning…",
                           "whatToNoticeWhileReading": "Watch X." },
              "exercises": [ { "kind": "quiz", "prompt": "?", "options": ["a","b"], "answerIndex": 1, "xp": 15 } ] }
          ]}
        ]}
        """
        let dto = try RoadmapDTO.decodeLoosely(from: json)
        let reading = try XCTUnwrap(dto.milestones[0].lessons[0].reading)
        XCTAssertEqual(reading.locator, "Book II")
        XCTAssertEqual(reading.anchorQuote, "Begin the morning…")
    }

    func testRoadmapDecodesWithoutReadingSlice() throws {
        // A payload with no `reading` key must decode (optional → nil), not throw.
        let json = """
        { "title": "T", "summary": "S", "milestones": [
          { "title": "M", "subtitle": "s", "lessons": [
            { "title": "L", "readingSummary": "r", "estimatedMinutes": 5,
              "exercises": [ { "kind": "quiz", "prompt": "?", "options": ["a","b"], "answerIndex": 1, "xp": 15 } ] }
          ]}
        ]}
        """
        let dto = try RoadmapDTO.decodeLoosely(from: json)
        XCTAssertNil(dto.milestones[0].lessons[0].reading)
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
