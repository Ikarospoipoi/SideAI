import XCTest
import SideAICore
import CryptoKit

final class OpenRouterTests: XCTestCase {
  func testPKCEStateAndLoopbackBinding() throws {
    let attempt = OpenRouterLoginAttempt(port: 51321)
    let parts = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(parts.host, "openrouter.ai")
    XCTAssertEqual(query["code_challenge"], Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
    XCTAssertEqual(query["code_challenge_method"], "S256")
    let url = URL(string: "http://127.0.0.1:51321/auth/callback?code=test-code&state=\(attempt.state)")!
    XCTAssertEqual(try attempt.exchangeBody(url)["code"].text, "test-code")
    for bad in ["http://127.0.0.1:51322/auth/callback?code=x&state=\(attempt.state)", "http://evil.example:51321/auth/callback?code=x&state=\(attempt.state)", "http://127.0.0.1:51321/auth/callback?code=x&state=wrong", "http://127.0.0.1:51321/auth/callback?code=x&state=\(attempt.state)&code=again"] {
      XCTAssertThrowsError(try attempt.exchangeBody(URL(string: bad)!))
    }
  }
}
