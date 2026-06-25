import XCTest
@testable import Mango

final class HTMLTextTests: XCTestCase {
    func testExtractStripsTagsAndScripts() {
        let html = """
        <html><head><title>Hello</title><style>.x{}</style></head>
        <body><script>evil()</script><h1>Heading</h1><p>One &amp; two.</p></body></html>
        """
        let text = HTMLText.extract(html)
        XCTAssertFalse(text.contains("evil"))
        XCTAssertFalse(text.contains(".x{}"))
        XCTAssertTrue(text.contains("Heading"))
        XCTAssertTrue(text.contains("One & two."))
    }

    func testTitleExtraction() {
        XCTAssertEqual(HTMLText.title("<title>My Page</title>", fallback: "x"), "My Page")
        XCTAssertEqual(HTMLText.title("<p>no title</p>", fallback: "Fallback"), "Fallback")
    }
}
