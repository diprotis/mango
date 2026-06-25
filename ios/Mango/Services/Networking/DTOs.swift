import Foundation

/// A normalized book produced by a content connector (local) or the backend.
struct ParsedBook: Sendable, Equatable {
    var id: String?
    var title: String
    var author: String?
    var wordCount: Int
    var estimatedMinutes: Int
    var coverHue: Double
    var excerpt: String
    var fullText: String
    var sourceKind: BookSourceKind
    var sourceValue: String
}

// MARK: - AI wire types (match shared/api/openapi.yaml)

struct RoadmapDTO: Codable, Sendable {
    var title: String
    var summary: String
    var milestones: [MilestoneDTO]
}

struct MilestoneDTO: Codable, Sendable {
    var title: String
    var subtitle: String
    var lessons: [LessonDTO]
}

struct LessonDTO: Codable, Sendable {
    var title: String
    var readingSummary: String
    var estimatedMinutes: Int
    var exercises: [ExerciseDTO]
}

struct ExerciseDTO: Codable, Sendable {
    var kind: String
    var prompt: String
    var options: [String]?
    var answerIndex: Int?
    var xp: Int
}

struct GradeResultDTO: Codable, Sendable {
    var correct: Bool?
    var score: Double
    var feedback: String
    var xpAwarded: Int
}

// MARK: - Request bodies

struct InlineBook: Codable, Sendable {
    var title: String
    var author: String?
    var text: String
}

struct ProfilePayload: Codable, Sendable {
    var goals: [String]
    var interests: [String]
    var readingLevel: String
    var dailyGoalUnits: Int
}

struct RoadmapRequest: Codable, Sendable {
    var bookId: String?
    var book: InlineBook?
    var profile: ProfilePayload
}

struct GradeRequest: Codable, Sendable {
    var kind: String
    var prompt: String
    var answer: String
}
