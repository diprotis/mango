import Foundation
import SwiftData

/// One row per calendar day the user was active — powers the streak calendar
/// and the daily-goal ring.
@Model
final class ActivityDay {
    @Attribute(.unique) var day: Date
    var xpEarned: Int
    var lessonsCompleted: Int
    var exercisesCompleted: Int

    init(day: Date, xpEarned: Int = 0, lessonsCompleted: Int = 0, exercisesCompleted: Int = 0) {
        self.day = day
        self.xpEarned = xpEarned
        self.lessonsCompleted = lessonsCompleted
        self.exercisesCompleted = exercisesCompleted
    }
}
