import Foundation

/// Presentation only: never retries, changes authentication, or infers account balances.
public struct ConnectionFeedback: Equatable {
  public let title: String
  public let detail: String
  public let diagnostic: HTTPFailureDiagnostic?
  public init(title: String, detail: String = "", diagnostic: HTTPFailureDiagnostic? = nil) {
    self.title = title; self.detail = detail; self.diagnostic = diagnostic
  }

  public static func failure(_ error: Error, title: String, secret: String = "") -> ConnectionFeedback {
    let detail: String
    if let failure = error as? HTTPChatFailure {
      let d = failure.diagnostic
      let code = d.errorCode ?? d.errorType ?? ""
      switch d.status {
      case 401:
        detail = "身份验证未通过。API 连接请检查密钥；账号连接请重新登录。"
      case 403:
        detail = "服务拒绝访问。请检查账号、项目和所选模型的使用权限。"
      default:
        if ["insufficient_quota", "quota_exceeded", "subscription_sharing_usage_limit_exceeded"].contains(code) {
          detail = "服务报告额度限制。请在对应服务查看可用额度与恢复时间；返回的信息不足以判断余额或重置时间。"
        } else if d.status == 429 || code == "rate_limit_exceeded" {
          detail = "请求受到频率限制。请稍后手动重试；若有服务返回的等待时间，可在请求诊断中查看。"
        } else if d.status == 404 || code == "model_not_found" {
          detail = "接口或模型不可用。请检查服务地址、API 协议和模型 ID；模型列表不可用时也可手动填写模型。"
        } else if d.status >= 500 {
          detail = "服务暂时异常。请稍后检查服务状态，再决定是否重试。"
        } else {
          detail = "服务未完成请求（HTTP \(d.status)）。请检查模型与请求设置，并查看请求诊断中的错误代码。"
        }
      }
    } else if let network = error as? URLError {
      switch network.code {
      case .timedOut:
        detail = "连接或响应超时。请检查网络与代理；请求可能已送达，重试前先核对已有结果。"
      case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
        detail = "网络连接失败或中断。请检查网络、代理和服务地址，再手动重试。"
      case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
        detail = "安全连接验证失败。请检查系统时间、代理证书和服务地址。"
      default:
        detail = "网络请求未完成（错误码 \(network.code.rawValue)）。请检查连接后手动重试。"
      }
    } else {
      detail = error.localizedDescription
    }
    let redacted = secret.isEmpty ? detail : detail.replacingOccurrences(of: secret, with: "[redacted]")
    return ConnectionFeedback(title: title, detail: redacted, diagnostic: (error as? HTTPChatFailure)?.diagnostic)
  }
}
