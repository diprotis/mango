import XCTest
@testable import Mango

final class StreakCalculatorTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return calendar.date(from: c)!
    }

    func testFirstActivityStartsStreak() {
        let state = StreakState(current: 0, longest: 0, lastActiveDay: nil, freezes: 0)
        let result = StreakCalculator.register(state, on: day(2026, 6, 25), calendar: calendar)
        XCTAssertEqual(result.state.current, 1)
        XCTAssertTrue(result.isNewDay)
    }

    func testSameDayDoesNotAdvance() {
        let state = StreakState(current: 3, longest: 3, lastActiveDay: day(2026, 6, 25), freezes: 0)
        let result = StreakCalculator.register(state, on: day(2026, 6, 25), calendar: calendar)
        XCTAssertEqual(result.state.current, 3)
        XCTAssertFalse(result.isNewDay)
    }

    func testConsecutiveDayAdvances() {
        let state = StreakState(current: 3, longest: 3, lastActiveDay: day(2026, 6, 25), freezes: 0)
        let result = StreakCalculator.register(state, on: day(2026, 6, 26), calendar: calendar)
        XCTAssertEqual(result.state.current, 4)
        XCTAssertEqual(result.state.longest, 4)
    }

    func testOneMissedDayConsumesFreeze() {
        let state = StreakState(current: 5, longest: 5, lastActiveDay: day(2026, 6, 25), freezes: 1)
        let result = StreakCalculator.register(state, on: day(2026, 6, 27), calendar: calendar)
        XCTAssertTrue(result.usedFreeze)
        XCTAssertEqual(result.state.current, 6)
        XCTAssertEqual(result.state.freezes, 0)
    }

    func testMissedDayWithoutFreezeResets() {
        let state = StreakState(current: 5, longest: 9, lastActiveDay: day(2026, 6, 25), freezes: 0)
        let result = StreakCalculator.register(state, on: day(2026, 6, 27), calendar: calendar)
        XCTAssertFalse(result.usedFreeze)
        XCTAssertEqual(result.state.current, 1)
        XCTAssertEqual(result.state.longest, 9)
    }

    func testLongGapResets() {
        let state = StreakState(current: 12, longest: 12, lastActiveDay: day(2026, 6, 20), freezes: 5)
        let result = StreakCalculator.register(state, on: day(2026, 6, 25), calendar: calendar)
        XCTAssertEqual(result.state.current, 1)
        XCTAssertEqual(result.state.freezes, 5)
    }
}
