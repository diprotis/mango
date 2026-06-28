import XCTest
@testable import Mango

/// Pure tests for the JourneyState enum and the Book.journeyState accessor.
/// The state *machine* (transitions) is a later slice (#3); this only covers the
/// value type's surface + the raw/computed storage mirror on Book.
final class JourneyStateTests: XCTestCase {
    func testAllCases() {
        XCTAssertEqual(JourneyState.allCases, [.notStarted, .reading, .finished])
    }

    func testRawValueRoundTrip() {
        for state in JourneyState.allCases {
            XCTAssertEqual(JourneyState(rawValue: state.rawValue), state)
            XCTAssertEqual(state.id, state.rawValue)
        }
    }

    func testUnknownRawValueIsNil() {
        XCTAssertNil(JourneyState(rawValue: "abandoned"))
    }

    func testTitles() {
        XCTAssertEqual(JourneyState.notStarted.title, "Not started")
        XCTAssertEqual(JourneyState.reading.title, "Reading")
        XCTAssertEqual(JourneyState.finished.title, "Finished")
    }

    func testSymbols() {
        XCTAssertEqual(JourneyState.notStarted.symbol, "bookmark")
        XCTAssertEqual(JourneyState.reading.symbol, "book")
        XCTAssertEqual(JourneyState.finished.symbol, "checkmark.seal.fill")
    }

    func testBookDefaultsToNotStarted() {
        let book = Book(id: "b1", title: "Test")
        XCTAssertEqual(book.journeyState, .notStarted)
    }

    func testBookJourneyStateAccessorMirrorsRawStorage() {
        let book = Book(id: "b1", title: "Test")
        book.journeyState = .reading
        XCTAssertEqual(book.journeyState, .reading)
        XCTAssertEqual(book.journeyStateRaw, JourneyState.reading.rawValue)

        book.journeyState = .finished
        XCTAssertEqual(book.journeyStateRaw, "finished")
    }
}
