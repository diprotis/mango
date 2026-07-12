import Foundation

/// An event that can move a Book's `JourneyState` (0008 ROADMAP §3.1, 4-event table).
/// `activityCompleted` is the single automatic nudge — completing any activity is the
/// earliest reading signal (reading is activity #1 of every lesson, ADR-0003). The
/// rest are user-initiated from the journey-status control.
enum JourneyEvent: CaseIterable {
    case start, activityCompleted, markFinished, reopen

    /// Menu presentation (strings only — keeps this file SwiftUI-free, mirroring how
    /// `JourneyState` owns its `title`/`symbol` in Models/Enums.swift).
    var title: String {
        switch self {
        case .start: return "Start journey"
        case .activityCompleted: return "Activity completed"  // automatic; never in menus
        case .markFinished: return "Mark finished"
        case .reopen: return "Reopen"
        }
    }

    var symbol: String {
        switch self {
        case .start: return "play.fill"
        case .activityCompleted: return "checkmark"
        case .markFinished: return "checkmark.seal"
        case .reopen: return "arrow.uturn.backward"
        }
    }
}

/// Pure journey-state transitions (SwiftData-free, like `LevelCurve`). Illegal
/// transitions are no-ops: the machine never throws, it just returns the input state.
/// Journey state is orthogonal to activity gating (ADR-0002) — nothing here reads or
/// gates lesson progress, and nothing auto-sets `finished`.
enum JourneyStateMachine {
    static func apply(_ event: JourneyEvent, to state: JourneyState) -> JourneyState {
        switch event {
        case .start, .activityCompleted:
            return state == .notStarted ? .reading : state
        case .markFinished:
            return .finished
        case .reopen:
            return state == .finished ? .reading : state
        }
    }

    /// Events a *user control* may offer from `state`: derived from the transition
    /// table (only real transitions, never the automatic `activityCompleted` nudge)
    /// so it can't drift from `apply` when events or states are added.
    static func manualEvents(from state: JourneyState) -> [JourneyEvent] {
        JourneyEvent.allCases.filter { event in
            event != .activityCompleted && apply(event, to: state) != state
        }
    }
}
