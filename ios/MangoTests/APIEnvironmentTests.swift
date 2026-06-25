import XCTest
@testable import Mango

final class APIEnvironmentTests: XCTestCase {
    func testMockHasNoURL() {
        XCTAssertNil(APIEnvironmentResolver.baseURL(for: .mock, personal: "https://x", beta: "https://y", prod: "https://z"))
    }

    func testProdResolvesFromBakedValue() {
        let url = APIEnvironmentResolver.baseURL(for: .prod, personal: "", beta: "", prod: "https://api.mango.app")
        XCTAssertEqual(url?.absoluteString, "https://api.mango.app")
    }

    func testBetaResolves() {
        let url = APIEnvironmentResolver.baseURL(for: .beta, personal: "", beta: "https://api.beta.mango.app", prod: "")
        XCTAssertEqual(url?.host, "api.beta.mango.app")
    }

    func testPersonalUsesItsOwnURL() {
        let url = APIEnvironmentResolver.baseURL(
            for: .personal, personal: "https://abc123.execute-api.us-east-1.amazonaws.com",
            beta: "https://b", prod: "https://p"
        )
        XCTAssertEqual(url?.host, "abc123.execute-api.us-east-1.amazonaws.com")
    }

    func testEmptyOrInvalidYieldsNil() {
        XCTAssertNil(APIEnvironmentResolver.baseURL(for: .beta, personal: "", beta: "", prod: "https://p"))
        XCTAssertNil(APIEnvironmentResolver.baseURL(for: .prod, personal: "", beta: "", prod: "not a url"))
        XCTAssertNil(APIEnvironmentResolver.baseURL(for: .personal, personal: "ftp://x.example.com", beta: "", prod: ""))
    }

    func testDefaultRealIsProdAndIsReal() {
        XCTAssertEqual(APIEnvironment.defaultReal, .prod)
        XCTAssertTrue(APIEnvironment.prod.isReal)
        XCTAssertTrue(APIEnvironment.beta.isReal)
        XCTAssertTrue(APIEnvironment.personal.isReal)
        XCTAssertFalse(APIEnvironment.mock.isReal)
    }
}
