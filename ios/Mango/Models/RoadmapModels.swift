import Foundation
import SwiftData

@Model
final class Roadmap {
    var title: String
    var summary: String
    var generatedAt: Date
    var book: Book?

    @Relationship(deleteRule: .cascade, inverse: \Milestone.roadmap)
    var milestones: [Milestone]

    init(title: String, summary: String) {
        self.title = title
        self.summary = summary
        self.generatedAt = .now
        self.milestones = []
    }

    var orderedMilestones: [Milestone] {
        milestones.sorted { $0.order < $1.order }
    }

    var allLessons: [Lesson] {
        orderedMilestones.flatMap { $0.orderedLessons }
    }

    var completedLessonCount: Int {
        allLessons.filter { $0.isCompleted }.count
    }

    var progress: Double {
        let all = allLessons
        guard !all.isEmpty else { return 0 }
        return Double(completedLessonCount) / Double(all.count)
    }
}

@Model
final class Milestone {
    var title: String
    var subtitle: String
    var order: Int
    var roadmap: Roadmap?

    @Relationship(deleteRule: .cascade, inverse: \Lesson.milestone)
    var lessons: [Lesson]

    init(title: String, subtitle: String, order: Int) {
        self.title = title
        self.subtitle = subtitle
        self.order = order
        self.lessons = []
    }

    var orderedLessons: [Lesson] {
        lessons.sorted { $0.order < $1.order }
    }
}

@Model
final class Lesson {
    var title: String
    var readingSummary: String
    var estimatedMinutes: Int
    var order: Int
    var completedAt: Date?
    var milestone: Milestone?

    @Relationship(deleteRule: .cascade, inverse: \Exercise.lesson)
    var exercises: [Exercise]

    init(title: String, readingSummary: String, estimatedMinutes: Int, order: Int) {
        self.title = title
        self.readingSummary = readingSummary
        self.estimatedMinutes = estimatedMinutes
        self.order = order
        self.completedAt = nil
        self.exercises = []
    }

    var orderedExercises: [Exercise] {
        exercises.sorted { $0.order < $1.order }
    }

    var isCompleted: Bool { completedAt != nil }

    var totalXP: Int {
        exercises.reduce(0) { $0 + $1.xp }
    }
}

@Model
final class Exercise {
    var kindRaw: String
    var prompt: String
    var options: [String]
    var answerIndex: Int?
    var xp: Int
    var order: Int

    // Response state
    var userAnswer: String?
    var chosenIndex: Int?
    var completedAt: Date?
    var score: Double?
    var feedback: String?

    var lesson: Lesson?

    init(
        kind: ExerciseKind,
        prompt: String,
        options: [String] = [],
        answerIndex: Int? = nil,
        xp: Int,
        order: Int
    ) {
        self.kindRaw = kind.rawValue
        self.prompt = prompt
        self.options = options
        self.answerIndex = answerIndex
        self.xp = xp
        self.order = order
        self.userAnswer = nil
        self.chosenIndex = nil
        self.completedAt = nil
        self.score = nil
        self.feedback = nil
    }

    var kind: ExerciseKind {
        get { ExerciseKind(rawValue: kindRaw) ?? .reflection }
        set { kindRaw = newValue.rawValue }
    }

    var isCompleted: Bool { completedAt != nil }
}
