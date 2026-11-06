import Foundation

public enum ProviderKind: String, Codable, CaseIterable {
  case openai, anthropic, deepseek, kimi, qwen, gemini, grok, openrouter, custom
  public var label: String {
    switch self { case .openai: return "OpenAI"; case .anthropic: return "Claude"; case .deepseek: return "DeepSeek"; case .kimi: return "Kimi"; case .qwen: return "Qwen"; case .gemini: return "Gemini"; case .grok: return "Grok"; case .openrouter: return "OpenRouter"; case .custom: return "自定义服务" }
  }
  public func preset() -> APIProfile {
    var p = APIProfile(); p.provider = self; p.name = label + " API"
    p.format = .chatCompletions
    switch self {
    case .openai: p.baseURL = "https://api.openai.com/v1"; p.format = .responses
    case .anthropic: p.baseURL = "https://api.anthropic.com/v1"; p.format = .anthropic
    case .deepseek: p.baseURL = "https://api.deepseek.com"
    case .kimi: p.baseURL = "https://api.moonshot.ai/v1"
    case .qwen: p.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    case .gemini: p.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    case .grok: p.baseURL = "https://api.x.ai/v1"
    case .openrouter: p.baseURL = "https://openrouter.ai/api/v1"
    case .custom: p.name = "自定义 API"; p.baseURL = ""
    }
    return p
  }
}
extension APIProfile {
  public var resolvedProvider: ProviderKind {
    // Recognize official hosts even if a user accidentally picks the wrong provider.
    let host = URL(string: baseURL)?.host?.lowercased() ?? ""
    if host == "api.openai.com" { return .openai }
    if host == "api.anthropic.com" { return .anthropic }
    if host == "generativelanguage.googleapis.com" { return .gemini }
    if host == "api.x.ai" { return .grok }
    if host == "openrouter.ai" { return .openrouter }
    if host == "api.deepseek.com" { return .deepseek }
    if ["api.moonshot.ai", "api.moonshot.cn"].contains(host) { return .kimi }
    if host.hasSuffix(".aliyuncs.com") && (host.contains("dashscope") || host.contains("maas")) { return .qwen }
    return provider ?? .custom
  }
  public var normalizedEndpoint: String {
    guard var u = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return baseURL }
    u.scheme = u.scheme?.lowercased(); u.host = u.host?.lowercased()
    if (u.scheme == "https" && u.port == 443) || (u.scheme == "http" && u.port == 80) { u.port = nil }
    while u.path.hasSuffix("/") { u.path.removeLast() }
    return u.string ?? baseURL
  }
  public var groupID: String { resolvedProvider == .custom ? "custom:" + normalizedEndpoint : resolvedProvider.rawValue }
  public var routeID: String { "api:" + id.uuidString }
  public func duplicates(_ other: APIProfile) -> Bool {
    id != other.id && normalizedEndpoint == other.normalizedEndpoint && format == other.format && auth == other.auth &&
      (auth == .chatgptPlan ? (oauthClientID == other.oauthClientID && oauthSubject == other.oauthSubject) : (accountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == (other.accountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}
public struct ConnectionRoute: Identifiable, Equatable {
  public let id: String
  public let name: String
  public let provider: ProviderKind
  public let backend: BackendKind
  public let profileID: UUID?
  public let groupID: String
  public init(id: String, name: String, provider: ProviderKind, backend: BackendKind, profileID: UUID? = nil, groupID: String? = nil) {
    self.id = id; self.name = name; self.provider = provider; self.backend = backend; self.profileID = profileID; self.groupID = groupID ?? provider.rawValue
  }
  public static let codex = ConnectionRoute(id: "codex-local", name: "Codex", provider: .openai, backend: .codex)
  public static let claude = ConnectionRoute(id: "claude-local", name: "Claude Code", provider: .anthropic, backend: .claude)
  public static let claudeChat = ConnectionRoute(id: "claude-chat", name: "Claude · 官方本机账号", provider: .anthropic, backend: .claude)
  public static let archive = ConnectionRoute(id: "chatgpt-archive", name: "ChatGPT 导入档案", provider: .openai, backend: .chatgptArchive)
  public static func api(_ profile: APIProfile) -> ConnectionRoute { .init(id: profile.routeID, name: profile.name, provider: profile.resolvedProvider, backend: .api, profileID: profile.id, groupID: profile.groupID) }
}
extension Conversation {
  public var routeID: String {
    switch engine {
    case .codex: return ConnectionRoute.codex.id
    case .claude: return claudeChatOnly == true ? ConnectionRoute.claudeChat.id : ConnectionRoute.claude.id
    case .accountRuntime: return accountRuntime?.route.id ?? "account:missing"
    case .api: return profileID.map { "api:" + $0.uuidString } ?? "api:missing"
    case .chatgptArchive: return ConnectionRoute.archive.id
    }
  }
}
public enum ConnectionPolicy {
  public static func activated(_ route: ConnectionRoute, in current: [String: String]) -> [String: String] {
    var result = current; result[route.selectionGroup] = route.id; return result
  }
  public static func isActive(_ route: ConnectionRoute, in current: [String: String]) -> Bool {
    if route.backend == .chatgptArchive { return false }
    return current[route.selectionGroup] == route.id
  }
}
