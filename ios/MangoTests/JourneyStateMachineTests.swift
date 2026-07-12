import XCTest
@testable import Mango

/// Exhaustive tests for the pure journey-state machine (ROADMAP 0008 §3.1, amended
/// 4-event table). Illegal transitions are no-ops; nothing here touches SwiftData.
final class JourneyStateMachineTests: XCTestCase {
    func testStart() {
        XCTAssertEqual(JourneyStateMachine.apply(.start, to: .notStarted), .reading)
        XCTAssertEqual(JourneyStateMachine.apply(.start, to: .reading), .reading)
        XCTAssertEqual(JourneyStateMachine.apply(.start, to: .finished), .finished)
    }

    func testActivityCompleted() {
        XCTAssertEqual(JourneyStateMachine.apply(.activityCompleted, to: .notStarted), .reading)
        XCTAssertEqual(JourneyStateMachine.apply(.activityCompleted, to: .reading), .reading)
        XCTAssertEqual(JourneyStateMachine.apply(.activityCompleted, to: .finished), .finished)
    }

    func testMarkFinishedAllowedFromAnyState() {
        XCTAssertEqual(JourneyStateMachine.apply(.markFinished, to: .notStarted), .finished)
        XCTAssertEqual(JourneyStateMachine.apply(.markFinished, to: .reading), .finished)
        XCTAssertEqual(JourneyStateMachine.apply(.markFinished, to: .finished), .finished)
    }

    func testReopenOnlyFromFinished() {
        XCTAssertEqual(JourneyStateMachine.apply(.reopen, to: .notStarted), .notStarted)
        XCTAssertEqual(JourneyStateMachine.apply(.reopen, to: .reading), .reading)
        XCTAssertEqual(JourneyStateMachine.apply(.reopen, to: .finished), .reading)
    }

    // MARK: manualEvents — what a user control may offer (no no-ops, no auto nudge)

    func testManualEventsPerState() {
        XCTAssertEqual(JourneyStateMachine.manualEvents(from: .notStarted), [.start, .markFinished])
        XCTAssertEqual(JourneyStateMachine.manualEvents(from: .reading), [.markFinished])
        XCTAssertEqual(JourneyStateMachine.manualEvents(from: .finished), [.reopen])
    }

    func testManualEventsNeverOfferTheAutomaticNudgeOrNoOps() {
        for state in JourneyState.allCases {
            let offered = JourneyStateMachine.manualEvents(from: state)
            XCTAssertFalse(offered.contains(.activityCompleted))
            for event in offered {
                XCTAssertNotEqual(JourneyStateMachine.apply(event, to: state), state)
            }
        }
    }
}
