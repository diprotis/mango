import Foundation

/// Calls the Anthropic Messages API directly from the device using a key stored
/// in the Keychain. Convenient for local testing before the backend is deployed;
/// not recommended for production (the key lives on-device).
struct DirectClaudeAIService: AIService {
    let apiKey: String
    var model: String = "claude-3-5-sonnet-latest"

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func generateRoadmap(book: AIBookContext, profile: AIProfileContext) async throws -> RoadmapDTO {
        let text = try await invoke(
            system: AIPrompts.roadmapSystem,
            user: AIPrompts.roadmapUser(book: book, profile: profile),
            maxTokens: 2500,
            temperature: 0.5
        )
        return try RoadmapDTO.decodeLoosely(from: text)
    }

    func grade(kind: ExerciseKind, prompt: String, answer: String) async throws -> GradeResultDTO {
        let text = try await invoke(
            system: AIPrompts.gradeSystem,
            user: AIPrompts.gradeUser(kind: kind, prompt: prompt, answer: answer),
            maxTokens: 600,
            temperature: 0.2
        )
        return try GradeResultDTO.decodeLoosely(from: text)
    }

    private func invoke(system: String, user: String, maxTokens: Int, temperature: Double) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = object["content"] as? [[String: Any]]
        else { throw AIError.badResponse }

        return content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
    }
}
