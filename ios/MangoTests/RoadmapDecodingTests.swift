import XCTest
@testable import Mango

final class RoadmapDecodingTests: XCTestCase {
    func testDecodeLooselyIgnoresSurroundingProse() throws {
        let response = """
        Sure! Here is your roadmap:
        ```json
        {
          "title": "Build Habits",
          "summary": "A practical path.",
          "milestones": [
            { "title": "Start", "subtitle": "Foundations", "lessons": [
              { "title": "Tiny", "readingSummary": "Small wins.", "estimatedMinutes": 5,
                "exercises": [ { "kind": "quiz", "prompt": "?", "options": ["a","b"], "answerIndex": 1, "xp": 15 } ] }
            ]}
          ]
        }
        ```
        Hope that helps!
        """
        let dto = try RoadmapDTO.decodeLoosely(from: response)
        XCTAssertEqual(dto.title, "Build Habits")
        XCTAssertEqual(dto.milestones.count, 1)
        XCTAssertEqual(dto.milestones[0].lessons[0].exercises[0].answerIndex, 1)
    }

    func testGradeResultDecode() throws {
        // Mirrors the real grade contract (openapi GradeResult / backend always
        // returns xpAwarded), so the fixture must carry it.
        let dto = try GradeResultDTO.decodeLoosely(
            from: "{\"score\":0.8,\"feedback\":\"Nice.\",\"xpAwarded\":20}"
        )
        XCTAssertEqual(dto.score, 0.8, accuracy: 0.001)
        XCTAssertEqual(dto.feedback, "Nice.")
        XCTAssertEqual(dto.xpAwarded, 20)
    }

    func testNoJSONThrows() {
        XCTAssertThrowsError(try RoadmapDTO.decodeLoosely(from: "no json here"))
    }
}
