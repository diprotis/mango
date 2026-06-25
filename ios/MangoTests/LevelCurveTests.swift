import XCTest
@testable import Mango

final class LevelCurveTests: XCTestCase {
    func testThresholds() {
        XCTAssertEqual(LevelCurve.totalXP(forLevel: 1), 0)
        XCTAssertEqual(LevelCurve.totalXP(forLevel: 2), 100)
        XCTAssertEqual(LevelCurve.totalXP(forLevel: 3), 300)
        XCTAssertEqual(LevelCurve.totalXP(forLevel: 4), 600)
        XCTAssertEqual(LevelCurve.totalXP(forLevel: 5), 1000)
    }

    func testLevelForXP() {
        XCTAssertEqual(LevelCurve.level(forXP: 0), 1)
        XCTAssertEqual(LevelCurve.level(forXP: 99), 1)
        XCTAssertEqual(LevelCurve.level(forXP: 100), 2)
        XCTAssertEqual(LevelCurve.level(forXP: 299), 2)
        XCTAssertEqual(LevelCurve.level(forXP: 1000), 5)
    }

    func testProgressFraction() {
        let p = LevelCurve.progress(forXP: 200) // L2 spans 100..300
        XCTAssertEqual(p.level, 2)
        XCTAssertEqual(p.into, 100)
        XCTAssertEqual(p.needed, 200)
        XCTAssertEqual(p.fraction, 0.5, accuracy: 0.0001)
    }

    func testTitles() {
        XCTAssertEqual(LevelCurve.title(forLevel: 1), "Curious Reader")
        XCTAssertEqual(LevelCurve.title(forLevel: 5), "Scholar")
    }
}
