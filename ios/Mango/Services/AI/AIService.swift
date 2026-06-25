import Foundation

struct AIBookContext: Sendable {
    var title: String
    var author: String?
    var excerpt: String
    var fullText: String
}

struct AIProfileContext: Sendable {
    var goals: [String]
    var interests: [String]
    var readingLevel: String
    var dailyGoalUnits: Int

    var payload: ProfilePayload {
        ProfilePayload(
            goals: goals, interests: interests,
            readingLevel: readingLevel, dailyGoalUnits: dailyGoalUnits
        )
    }
}

/// Generates roadmaps and grades free-text answers. Implementations: Remote
/// (AWS backend), Direct (Anthropic API on device), and Mock (offline).
protocol AIService: Sendable {
    func generateRoadmap(book: AIBookContext, profile: AIProfileContext) async throws -> RoadmapDTO
    func grade(kind: ExerciseKind, prompt: String, answer: String) async throws -> GradeResultDTO
}

enum AIError: LocalizedError {
    case noJSON
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noJSON: return "The model response did not contain valid JSON."
        case .badResponse: return "Unexpected response from the model."
        case let .http(code, message): return "Model API error \(code): \(message)"
        }
    }
}

extension RoadmapDTO {
    /// Pull the first JSON object out of a model response and decode it.
    static func decodeLoosely(from text: String) throws -> RoadmapDTO {
        let data = try JSONExtraction.firstObject(in: text)
        return try JSONDecoder().decode(RoadmapDTO.self, from: data)
    }
}

extension GradeResultDTO {
    static func decodeLoosely(from text: String) throws -> GradeResultDTO {
        let data = try JSONExtraction.firstObject(in: text)
        return try JSONDecoder().decode(GradeResultDTO.self, from: data)
    }
}

enum JSONExtraction {
    static func firstObject(in text: String) throws -> Data {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { throw AIError.noJSON }
        return Data(text[start...end].utf8)
    }
}
