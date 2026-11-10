import XCTest
@testable import SideAICore
final class HTTPFailureTests: XCTestCase {
  func testStreamFailurePreservesHTTP200AndSafeFieldsOnly() throws {
    let raw: JSON = .object(["type": .string("error"), "error": .object([
      "type": .string("invalid_request_error"), "code": .string("subscription_sharing_usage_limit_exceeded"),
      "message": .string("Bearer secret-private-value"), "reset_after_seconds": .number(120), "token": .string("secret-private-value")])])
    let d = HTTPFailureDiagnostic(url: URL(string: "https://api.openai.com/v1/responses?token=secret-private-value")!, status: 200,
      headers: ["Set-Cookie": "secret-private-value", "Authorization": "secret-private-value", "Retry-After": "120", "x-ratelimit-reset-tokens": "6m0s"], payload: raw)
    XCTAssertEqual(d.status, 200); XCTAssertEqual(d.path, "/v1/responses"); XCTAssertEqual(d.errorCode, "subscription_sharing_usage_limit_exceeded")
    XCTAssertEqual(d.resetFields["retry-after"], "120"); XCTAssertEqual(d.resetFields["x-ratelimit-reset-tokens"], "6m0s")
    let encoded = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
    XCTAssertFalse(encoded.contains("secret-private-value")); XCTAssertFalse(encoded.contains("Set-Cookie"))
  }
  func testMissingResetIsNotInventedAndNestedFailureParsed() {
    let d = HTTPFailureDiagnostic(url: URL(string: "https://api.openai.com/v1/responses")!, status: 200, headers: [:], payload: .object(["type": .string("response.failed"), "response": .object(["error": .object(["code": .string("subscription_sharing_usage_limit_exceeded")])])]))
    XCTAssertEqual(d.event, "response.failed"); XCTAssertNil(d.errorType); XCTAssertTrue(d.resetFields.isEmpty)
  }
}
