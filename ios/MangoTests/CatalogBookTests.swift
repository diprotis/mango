import XCTest
@testable import Mango

final class CatalogBookTests: XCTestCase {

    // MARK: - CatalogBook (list item)

    func testDecodeFullPayload() throws {
        let json = """
        {
          "id": "the-republic",
          "title": "The Republic",
          "author": "Plato",
          "excerpt": "Justice in the soul and the city.",
          "coverHue": 210.5,
          "wordCount": 120000,
          "estimatedMinutes": 600
        }
        """
        let book = try JSONDecoder().decode(CatalogBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.id, "the-republic")
        XCTAssertEqual(book.title, "The Republic")
        XCTAssertEqual(book.author, "Plato")
        XCTAssertEqual(book.excerpt, "Justice in the soul and the city.")
        XCTAssertEqual(book.coverHue, 210.5, accuracy: 0.001)
        XCTAssertEqual(book.wordCount, 120000)
        XCTAssertEqual(book.estimatedMinutes, 600)
    }

    func testDecodeLenientWithMissingOptionalFields() throws {
        // Only id + title present; everything else should default, not throw.
        let json = #"{ "id": "x", "title": "Untitled Classic" }"#
        let book = try JSONDecoder().decode(CatalogBook.self, from: Data(json.utf8))
        XCTAssertNil(book.author)
        XCTAssertEqual(book.excerpt, "")
        XCTAssertEqual(book.coverHue, 28, accuracy: 0.001) // Mango default hue
        XCTAssertEqual(book.wordCount, 0)
        XCTAssertEqual(book.estimatedMinutes, 0)
    }

    func testDecodeMissingRequiredIdThrows() {
        let json = #"{ "title": "No Id Here" }"#
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogBook.self, from: Data(json.utf8)))
    }

    // MARK: - CatalogBookDetail (with text)

    func testDecodeDetailWithText() throws {
        let json = """
        {
          "id": "meditations",
          "title": "Meditations",
          "author": "Marcus Aurelius",
          "coverHue": 28,
          "text": "Begin the morning by saying to thyself..."
        }
        """
        let detail = try JSONDecoder().decode(CatalogBookDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.id, "meditations")
        XCTAssertTrue(detail.text.hasPrefix("Begin the morning"))
        XCTAssertEqual(detail.excerpt, "") // absent → default
    }

    func testDetailRoundTrips() throws {
        let original = CatalogBookDetail(
            id: "a", title: "T", author: "A", excerpt: "e",
            coverHue: 12, wordCount: 100, estimatedMinutes: 5, text: "body"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogBookDetail.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Bundled offline catalog

    func testBundledSamplesAreNonEmptyAndCarryText() {
        XCTAssertFalse(CatalogSamples.all.isEmpty)
        for book in CatalogSamples.all {
            let detail = CatalogSamples.detail(for: book.id)
            XCTAssertNotNil(detail, "missing detail for \(book.id)")
            XCTAssertFalse(detail?.text.isEmpty ?? true, "empty text for \(book.id)")
            XCTAssertGreaterThan(book.estimatedMinutes, 0)
        }
    }

    func testBundledDetailLookupReturnsNilForUnknownID() {
        XCTAssertNil(CatalogSamples.detail(for: "does-not-exist"))
    }
}
