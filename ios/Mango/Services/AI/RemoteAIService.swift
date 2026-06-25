import Foundation

/// Calls the Mango AWS backend, which holds the Anthropic key server-side.
struct RemoteAIService: AIService {
    let client: APIClient

    func generateRoadmap(book: AIBookContext, profile: AIProfileContext) async throws -> RoadmapDTO {
        let request = RoadmapRequest(
            bookId: nil,
            book: InlineBook(
                title: book.title,
                author: book.author,
                text: String(book.fullText.prefix(12000))
            ),
            profile: profile.payload
        )
        return try await client.postJSON("/v1/roadmaps/generate", body: request)
    }

    func grade(kind: ExerciseKind, prompt: String, answer: String) async throws -> GradeResultDTO {
        let request = GradeRequest(kind: kind.rawValue, prompt: prompt, answer: answer)
        return try await client.postJSON("/v1/exercises/grade", body: request)
    }
}
