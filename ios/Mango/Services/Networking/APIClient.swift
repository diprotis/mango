import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case badStatus(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No backend is configured."
        case let .badStatus(code, body): return "Server returned \(code): \(body)"
        case let .decoding(message): return "Could not read the server response: \(message)"
        case let .transport(message): return "Network error: \(message)"
        }
    }
}

/// Thin async JSON client for the Mango backend (API Gateway HTTP API).
///
/// Every request carries the `x-mango-user` device id, and — when a session is
/// active — an `Authorization: Bearer <id token>` header. Deployed (authorizer-
/// protected) stages require the bearer token; local/dev stages also accept the
/// `x-mango-user` fallback.
struct APIClient: Sendable {
    let baseURL: URL
    let deviceUserId: String
    var authToken: String?

    /// HTTP methods the client uses. Kept tiny — the backend is a small REST API.
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    // MARK: - Convenience verbs

    /// POST an `Encodable` body and decode the JSON response.
    func postJSON<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encodeBody(body)
        let responseData = try await send(method: .post, path: path, body: data)
        return try decode(responseData, as: Response.self)
    }

    /// GET a path and decode the JSON response.
    func getJSON<Response: Decodable>(
        _ path: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let responseData = try await send(method: .get, path: path, body: nil)
        return try decode(responseData, as: Response.self)
    }

    /// DELETE a path, ignoring any response body. Throws on a non-2xx status.
    func delete(_ path: String) async throws {
        _ = try await send(method: .delete, path: path, body: nil)
    }

    // MARK: - Core request

    /// Build, send, and validate a request. Returns the raw response body (which
    /// may be empty for 204s). Shared by every verb so headers stay consistent.
    private func send(method: Method, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method.rawValue
        request.setValue(deviceUserId, forHTTPHeaderField: "x-mango-user")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken { request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Coding helpers

    private func encodeBody<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func decode<Response: Decodable>(_ data: Data, as type: Response.Type) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}
