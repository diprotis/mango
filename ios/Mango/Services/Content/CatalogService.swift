import Foundation

/// Fetches the backend's curated, public-domain catalog so a signed-in user can
/// add a book and build a roadmap end-to-end. Backed by an `APIClient` resolved
/// from the active environment (the same one `AIServiceProvider`/`RemoteAIService`
/// use), so it inherits the bearer token and `x-mango-user` headers.
///
/// When no real backend is configured (Offline/Mock), `list()`/`detail()` throw
/// `APIError.notConfigured` and the UI falls back to a bundled sample.
struct CatalogService: Sendable {
    let client: APIClient?

    init(client: APIClient?) {
        self.client = client
    }

    /// All catalog books. `GET /v1/catalog` → `{ "items": [CatalogBook] }`.
    func list() async throws -> [CatalogBook] {
        guard let client else { throw APIError.notConfigured }
        let response: CatalogListResponse = try await client.getJSON("/v1/catalog")
        return response.items
    }

    /// A single catalog book with full text. `GET /v1/catalog/{id}`.
    func detail(_ id: String) async throws -> CatalogBookDetail {
        guard let client else { throw APIError.notConfigured }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await client.getJSON("/v1/catalog/\(encoded)")
    }
}

/// The list endpoint wraps its array in an `items` key.
private struct CatalogListResponse: Decodable {
    let items: [CatalogBook]
}
