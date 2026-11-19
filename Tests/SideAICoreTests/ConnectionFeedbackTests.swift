import XCTest
@testable import SideAICore

final class ConnectionFeedbackTests: XCTestCase {
  private func failure(status: Int, code: String = "", message: String = "private-response") -> HTTPChatFailure {
    HTTPChatFailure(diagnostic: HTTPFailureDiagnostic(url: URL(string: "https://example.com/v1/responses")!, status: status,
      headers: [:], payload: .object(["error": .object(["code": .string(code)])])), message: message)
  }

  func testHTTP200QuotaFailureIsNotSuccessfulConnectionOrRateLimit() {
    let feedback = ConnectionFeedback.failure(failure(status: 200, code: "subscription_sharing_usage_limit_exceeded"), title: "失败")
    XCTAssertTrue(feedback.detail.contains("额度限制"))
    XCTAssertFalse(feedback.detail.contains("频率限制"))
    XCTAssertFalse(feedback.detail.contains("private-response"))
    XCTAssertTrue(feedback.detail.contains("不足以判断"))
  }

  func testQuotaTakesPrecedenceOver429AndAuthenticationOverQuota() {
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 429, code: "insufficient_quota"), title: "失败").detail.contains("额度限制"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 429), title: "失败").detail.contains("频率限制"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 401, code: "insufficient_quota"), title: "失败").detail.contains("身份验证"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 403), title: "失败").detail.contains("权限"))
  }

  func testModelServerAndUnknownErrorsGiveDistinctAdvice() {
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 404), title: "失败").detail.contains("模型 ID"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 200, code: "model_not_found"), title: "失败").detail.contains("模型 ID"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 503), title: "失败").detail.contains("服务暂时异常"))
    XCTAssertTrue(ConnectionFeedback.failure(failure(status: 400), title: "失败").detail.contains("HTTP 400"))
  }

  func testNetworkAdviceDoesNotExposeURLOrPromiseSafeReplay() {
    let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://example.com?secret=private"])
    let detail = ConnectionFeedback.failure(error, title: "失败").detail
    XCTAssertTrue(detail.contains("可能已送达")); XCTAssertFalse(detail.contains("private"))
    XCTAssertTrue(ConnectionFeedback.failure(URLError(.notConnectedToInternet), title: "失败").detail.contains("代理"))
    XCTAssertTrue(ConnectionFeedback.failure(URLError(.serverCertificateUntrusted), title: "失败").detail.contains("证书"))
  }

  func testFallbackRetainsActionableMessageButRedactsCredential() {
    let detail = ConnectionFeedback.failure(ProtocolError.message("请检查 fixture-secret"), title: "失败", secret: "fixture-secret").detail
    XCTAssertEqual(detail, "请检查 [redacted]")
  }
}
