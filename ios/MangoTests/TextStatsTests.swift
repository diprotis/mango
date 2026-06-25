import XCTest
@testable import Mango

final class TextStatsTests: XCTestCase {
    func testWordCount() {
        XCTAssertEqual(TextStats.wordCount("one two three"), 3)
        XCTAssertEqual(TextStats.wordCount(" leading and  spaced \n new "), 4)
    }

    func testEstimatedMinutes() {
        XCTAssertEqual(TextStats.estimatedMinutes(words: 0), 1)
        XCTAssertEqual(TextStats.estimatedMinutes(words: 400, wpm: 200), 2)
    }

    func testCoverHueStableAndInRange() {
        let a = TextStats.coverHue("Atomic Habits")
        let b = TextStats.coverHue("Atomic Habits")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a >= 0 && a < 360)
    }

    func testExcerptTruncates() {
        let long = String(repeating: "word ", count: 200)
        let ex = TextStats.excerpt(long, length: 50)
        XCTAssertTrue(ex.hasSuffix("…"))
        XCTAssertLessThanOrEqual(ex.count, 51)
    }
}
