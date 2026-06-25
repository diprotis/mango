import Foundation

struct StreakState: Equatable {
    var current: Int
    var longest: Int
    var lastActiveDay: Date?
    var freezes: Int
}

struct StreakResult: Equatable {
    var state: StreakState
    var usedFreeze: Bool
    var isNewDay: Bool
}

/// Pure, day-granular streak logic — kept free of SwiftData so it can be unit
/// tested exhaustively. A one-day gap is forgiven if a freeze is available.
enum StreakCalculator {
    static func register(_ state: StreakState, on date: Date, calendar: Calendar = .current) -> StreakResult {
        let today = calendar.startOfDay(for: date)

        guard let last = state.lastActiveDay.map({ calendar.startOfDay(for: $0) }) else {
            var next = state
            next.current = 1
            next.longest = max(state.longest, 1)
            next.lastActiveDay = today
            return StreakResult(state: next, usedFreeze: false, isNewDay: true)
        }

        let gap = calendar.dateComponents([.day], from: last, to: today).day ?? 0
        if gap <= 0 {
            return StreakResult(state: state, usedFreeze: false, isNewDay: false)
        }

        var next = state
        var usedFreeze = false
        if gap == 1 {
            next.current += 1
        } else if gap == 2 && state.freezes > 0 {
            next.freezes -= 1
            next.current += 1
            usedFreeze = true
        } else {
            next.current = 1
        }
        next.longest = max(next.longest, next.current)
        next.lastActiveDay = today
        return StreakResult(state: next, usedFreeze: usedFreeze, isNewDay: true)
    }
}
