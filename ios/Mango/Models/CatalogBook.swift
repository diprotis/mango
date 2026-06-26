import Foundation

/// A book offered by the backend catalog (`GET /v1/catalog`). These are
/// curated, public-domain titles the user can add with one tap; the heavy
/// `text` is fetched lazily via the detail endpoint.
///
/// Decodes leniently: `author` may be absent, and `coverHue` defaults to the
/// Mango terracotta hue when the backend omits it.
struct CatalogBook: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let author: String?
    let excerpt: String
    let coverHue: Double
    let wordCount: Int
    let estimatedMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, title, author, excerpt, coverHue, wordCount, estimatedMinutes
    }

    init(
        id: String,
        title: String,
        author: String? = nil,
        excerpt: String = "",
        coverHue: Double = 28,
        wordCount: Int = 0,
        estimatedMinutes: Int = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.excerpt = excerpt
        self.coverHue = coverHue
        self.wordCount = wordCount
        self.estimatedMinutes = estimatedMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        coverHue = try container.decodeIfPresent(Double.self, forKey: .coverHue) ?? 28
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 0
    }
}

/// The detail variant (`GET /v1/catalog/{id}`): everything in `CatalogBook`
/// plus the full `text` used to seed a `Book` and build a roadmap.
struct CatalogBookDetail: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let author: String?
    let excerpt: String
    let coverHue: Double
    let wordCount: Int
    let estimatedMinutes: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case id, title, author, excerpt, coverHue, wordCount, estimatedMinutes, text
    }

    init(
        id: String,
        title: String,
        author: String? = nil,
        excerpt: String = "",
        coverHue: Double = 28,
        wordCount: Int = 0,
        estimatedMinutes: Int = 0,
        text: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.excerpt = excerpt
        self.coverHue = coverHue
        self.wordCount = wordCount
        self.estimatedMinutes = estimatedMinutes
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        coverHue = try container.decodeIfPresent(Double.self, forKey: .coverHue) ?? 28
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 0
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}
