import Foundation

/// Maps XP to levels with a smooth, slightly super-linear curve.
/// L2 = 100xp, L3 = 300, L4 = 600, L5 = 1000, L6 = 1500 ...
enum LevelCurve {
    static func totalXP(forLevel level: Int) -> Int {
        guard level > 1 else { return 0 }
        let n = Double(level - 1)
        return Int((50 * n * (n + 1)).rounded())
    }

    static func level(forXP xp: Int) -> Int {
        var level = 1
        while totalXP(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    /// Progress within the current level.
    static func progress(forXP xp: Int) -> (level: Int, into: Int, needed: Int, fraction: Double) {
        let lvl = level(forXP: xp)
        let base = totalXP(forLevel: lvl)
        let next = totalXP(forLevel: lvl + 1)
        let needed = max(1, next - base)
        let into = max(0, xp - base)
        return (lvl, into, needed, Double(into) / Double(needed))
    }

    static func title(forLevel level: Int) -> String {
        switch level {
        case ...1: return "Curious Reader"
        case 2: return "Page Turner"
        case 3, 4: return "Practitioner"
        case 5...7: return "Scholar"
        case 8...11: return "Mentor"
        default: return "Sage"
        }
    }
}
