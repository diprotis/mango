import Foundation
import SwiftData

/// The "player" — a single instance per install holds profile + gamification state.
@Model
final class UserProfile {
    var name: String
    var goals: [String]
    var interests: [String]
    var readingLevelRaw: String
    var dailyGoalUnits: Int

    // Gamification
    var totalXP: Int
    var currentStreak: Int
    var longestStreak: Int
    var freezesAvailable: Int
    var lastActiveDay: Date?

    // Lifecycle
    var hasOnboarded: Bool
    var reminderHour: Int?
    var reminderMinute: Int
    var createdAt: Date

    init(name: String = "") {
        self.name = name
        self.goals = []
        self.interests = []
        self.readingLevelRaw = ReadingLevel.focused.rawValue
        self.dailyGoalUnits = 2
        self.totalXP = 0
        self.currentStreak = 0
        self.longestStreak = 0
        self.freezesAvailable = 1
        self.lastActiveDay = nil
        self.hasOnboarded = false
        self.reminderHour = nil
        self.reminderMinute = 0
        self.createdAt = .now
    }

    var readingLevel: ReadingLevel {
        get { ReadingLevel(rawValue: readingLevelRaw) ?? .focused }
        set { readingLevelRaw = newValue.rawValue }
    }

    var level: Int { LevelCurve.level(forXP: totalXP) }
    var levelTitle: String { LevelCurve.title(forLevel: level) }
}
