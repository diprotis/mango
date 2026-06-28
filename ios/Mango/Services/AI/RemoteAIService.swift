import Foundation

/// Calls the Mango AWS backend, which runs generation on Amazon Bedrock.
struct RemoteAIService: AIService {
    let client: APIClient

    /// Roadmap generation is asynchronous server-side (Opus 4.8 exceeds the API
    /// Gateway 30s limit): POST enqueues and returns 202 + a jobId, then we poll
    /// GET /v1/roadmaps/jobs/{jobId} until it completes or fails.
    private static let pollInterval: Duration = .seconds(2)
    // Full-book grounding makes real generation run longer (the worker Lambda has a
    // 300s budget), so poll up to ~5 min to match rather than time out early.
    private static let maxPolls = 150  // ~300s ceiling

    /// How much book text to send for grounding the roadmap (and the reading-slice
    /// locators/anchor quotes). We ground on the whole book; the only hard ceiling is
    /// the model's context window. Keep in sync with the backend `GROUNDING_CHAR_BUDGET`
    /// in `prompts.py`.
    static let groundingCharBudget = 600_000

    func generateRoadmap(book: AIBookContext, profile: AIProfileContext) async throws -> RoadmapDTO {
        let request = RoadmapRequest(
            bookId: nil,
            book: InlineBook(
                title: book.title,
                author: book.author,
                text: String(book.fullText.prefix(Self.groundingCharBudget))
            ),
            profile: profile.payload
        )
        let job: RoadmapJobDTO = try await client.postJSON("/v1/roadmaps/generate", body: request)
        return try await pollRoadmap(jobId: job.jobId, initial: job)
    }

    /// Poll a roadmap job to completion. Returns the roadmap on success, or throws
    /// an `AIError` on backend failure / timeout.
    private func pollRoadmap(jobId: String, initial: RoadmapJobDTO) async throws -> RoadmapDTO {
        var job = initial
        for _ in 0..<Self.maxPolls {
            switch job.parsedStatus {
            case .complete:
                if let roadmap = job.roadmap { return roadmap }
                throw AIError.badResponse
            case .failed:
                throw AIError.http(502, job.error ?? "roadmap generation failed")
            case .pending, .none:
                try await Task.sleep(for: Self.pollInterval)
                job = try await client.getJSON("/v1/roadmaps/jobs/\(jobId)")
            }
        }
        // Timed out waiting — surface as a retryable error.
        throw AIError.http(504, "Roadmap is taking longer than expected. Please try again.")
    }

    func grade(kind: ExerciseKind, prompt: String, answer: String) async throws -> GradeResultDTO {
        let request = GradeRequest(kind: kind.rawValue, prompt: prompt, answer: answer)
        return try await client.postJSON("/v1/exercises/grade", body: request)
    }
}
