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

/// The async roadmap-job envelope returned by POST /v1/roadmaps/generate (202)
/// and GET /v1/roadmaps/jobs/{jobId}. `roadmap` is present only when complete;
/// `error` only when failed.
struct RoadmapJobDTO: Codable, Sendable {
    var jobId: String
    var status: String
    var roadmap: RoadmapDTO?
    var error: String?

    enum Status: String {
        case pending, complete, failed
    }

    var parsedStatus: Status? { Status(rawValue: status) }
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
    /// Optional structured pointer to the slice to read for this lesson. Absent →
    /// the client falls back to `readingSummary` when synthesizing the reading activity.
    var reading: ReadingSliceDTO? = nil
    var exercises: [ExerciseDTO]
}

/// The slice of the book to read for a lesson — chapter/section for print readers,
/// plus a verbatim opening quote searchable in Kindle. Never page numbers (the model
/// can't see them; they vary by edition). All fields optional; decoded leniently.
struct ReadingSliceDTO: Codable, Sendable {
    var locator: String?
    var anchorQuote: String?
    var whatToNoticeWhileReading: String?
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
