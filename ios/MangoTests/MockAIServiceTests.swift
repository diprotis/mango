import XCTest
@testable import Mango

final class MockAIServiceTests: XCTestCase {
    func testRoadmapIsWellFormed() async throws {
        let service = MockAIService()
        let book = AIBookContext(title: "Deep Work", author: "Cal Newport", excerpt: "", fullText: "Focus is a skill.")
        let profile = AIProfileContext(goals: ["focus"], interests: ["productivity"], readingLevel: "focused", dailyGoalUnits: 2)

        let roadmap = try await service.generateRoadmap(book: book, profile: profile)
        XCTAssertFalse(roadmap.milestones.isEmpty)
        XCTAssertTrue(roadmap.milestones.allSatisfy { !$0.lessons.isEmpty })
        XCTAssertTrue(roadmap.title.contains("Deep Work"))

        let everyExercise = roadmap.milestones.flatMap { $0.lessons.flatMap(\.exercises) }
        XCTAssertTrue(everyExercise.allSatisfy { $0.xp > 0 })
    }

    func testGradeReturnsXP() async throws {
        let result = try await MockAIService().grade(
            kind: .reflection,
            prompt: "Where does this apply?",
            answer: "In my morning routine, specifically before checking email."
        )
        XCTAssertGreaterThan(result.xpAwarded, 0)
        XCTAssertGreaterThan(result.score, 0)
    }
}
