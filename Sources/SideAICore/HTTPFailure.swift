import Foundation

/// Allowlist only. Never retain request headers, bodies, response messages or arbitrary JSON.
public struct HTTPFailureDiagnostic: Codable, Equatable {
  public var host: String
  public var path: String
  public var status: Int
  public var event: String?
  public var errorType: String?
  public var errorCode: String?
  public var resetFields: [String: String]
  public var recordedAt = Date()
  public init(url: URL, status: Int, headers: [String: String], payload: JSON) {
    host = url.host ?? ""; path = url.path; self.status = status
    func identifier(_ value: String?) -> String? {
      guard let value, value.range(of: #"^[a-z][a-z0-9_.]{0,79}$"#, options: .regularExpression) != nil else { return nil }
      return value
    }
    event = identifier(payload["type"].string)
    let error = payload["error"] == .null ? payload["response"]["error"] : payload["error"]
    errorType = identifier(error["type"].string); errorCode = identifier(error["code"].string)
    resetFields = [:]
    func reset(_ value: String?) -> String? {
      guard let value, value.count <= 80,
        value.range(of: #"^(?:[0-9]+(?:\.[0-9]+)?(?:ms|s|m|h|d)?)+$|^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+Z-]+$|^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9:]{8} GMT$"#, options: .regularExpression) != nil else { return nil }
      return value
    }
    for (name, value) in headers where ["retry-after", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "x-ratelimit-reset-project-tokens"].contains(name.lowercased()) {
      if let value = reset(value) { resetFields[name.lowercased()] = value }
    }
    for name in ["reset_at", "resets_at", "reset_after", "reset_after_seconds", "retry_after", "retry_after_seconds"] {
      for (prefix, object) in [("error.", error), ("", payload)] {
        let raw = object[name]
        let value: String?
        switch raw { case .number(let n): value = String(n); case .string(let s): value = s; default: value = nil }
        if let value = reset(value) { resetFields[prefix + name] = value }
      }
    }
  }
  public var summary: String {
    "\(host)\(path)\nHTTP \(status)\n事件：\(event ?? "未提供")\n错误类型：\(errorType ?? "未提供")\n错误代码：\(errorCode ?? "未提供")\n重置字段：" + (resetFields.isEmpty ? "未提供" : resetFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
  }
}
public struct HTTPChatFailure: LocalizedError {
  public let diagnostic: HTTPFailureDiagnostic
  public let message: String
  public init(diagnostic: HTTPFailureDiagnostic, message: String) { self.diagnostic = diagnostic; self.message = message }
  public var errorDescription: String? { message }
}
