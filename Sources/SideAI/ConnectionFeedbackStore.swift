import Foundation
import SideAICore

extension SessionStore {
  // Keep Claude's existing presentation and execution paths unchanged.
  func supportsConnectionFeedback(_ route: ConnectionRoute) -> Bool {
    guard route.backend != .claude, route.provider != .anthropic, route.backend != .chatgptArchive else { return false }
    if let profile = profiles.first(where: { $0.id == route.profileID }) {
      guard profile.format != .anthropic,
        !profile.defaultModel.localizedCaseInsensitiveContains("claude"),
        !state.conversations.contains(where: { $0.profileID == profile.id && ($0.modelID?.localizedCaseInsensitiveContains("claude") == true) }) else { return false }
    }
    return true
  }

  func connectionFeedback(for route: ConnectionRoute) -> ConnectionFeedback? {
    guard supportsConnectionFeedback(route) else { return nil }
    guard routes.contains(where: { $0.id == route.id }) else { return ConnectionFeedback(title: "连接配置已移除", detail: "历史仍可查看；请在连接管理恢复配置。") }
    guard isRouteActive(route) else { return ConnectionFeedback(title: "备用连接", detail: "打开此连接后再发送。") }
    if route.backend == .codex {
      if connecting { return ConnectionFeedback(title: "正在连接 Codex…") }
      return ConnectionFeedback(title: ready ? "Codex 执行器已连接" : connection,
        detail: ready ? "登录状态已读取；模型可用性和额度以实际请求为准。" : "请在连接管理检查登录与 CLI 路径。")
    }
    return connectionFeedbackByRoute[route.id] ?? ConnectionFeedback(title: "已配置 · 尚未验证请求",
      detail: "配置存在不代表当前网络、登录和模型额度均可用。")
  }

  func recordConnectionFeedback(_ feedback: ConnectionFeedback, for route: ConnectionRoute) {
    guard supportsConnectionFeedback(route), routes.contains(where: { $0.id == route.id }) else { return }
    connectionFeedbackByRoute[route.id] = feedback
  }

  func connectionFailureMessage(_ error: Error, for route: ConnectionRoute, secret: String = "") -> String {
    guard supportsConnectionFeedback(route) else {
      return secret.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: secret, with: "[redacted]")
    }
    let feedback = ConnectionFeedback.failure(error, title: "上次请求失败", secret: secret)
    recordConnectionFeedback(feedback, for: route)
    return feedback.detail + "\n未自动重发；已有内容已保留，请核对后再决定是否重试。"
  }
}
