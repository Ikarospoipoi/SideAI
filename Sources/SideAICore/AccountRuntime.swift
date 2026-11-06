import Foundation

/// Official local runtimes own OAuth and renewal. SideAI never extracts their account tokens.
public enum AccountRuntime: String, Codable, CaseIterable {
  case kimi, gemini, grok
  public var provider: ProviderKind { ProviderKind(rawValue: rawValue)! }
  public var name: String { provider.label }
  public var route: ConnectionRoute { .init(id: "account:" + rawValue, name: name, provider: provider, backend: .accountRuntime) }
  public var executable: String { self == .gemini ? "agy" : rawValue }
  public var npmPackage: String? {
    switch self {
    case .kimi: return "@moonshot-ai/kimi-code@2.5.1"
    case .gemini: return nil
    case .grok: return "@xai-official/grok@1.0.77"
    }
  }
  public var authMethod: String {
    switch self { case .kimi: return "login"; case .gemini: return "oauth-personal"; case .grok: return "grok.com" }
  }
  public var environmentKey: String {
    switch self { case .kimi: return "KIMI_CODE_HOME"; case .gemini: return "ANTIGRAVITY_GEMINI_DIR"; case .grok: return "GROK_HOME" }
  }
  public var loginHosts: Set<String> {
    switch self {
    case .kimi: return ["auth.kimi.com", "auth.kimi.ai", "www.kimi.com", "www.kimi.ai", "kimi.com", "kimi.ai"]
    case .gemini: return ["accounts.google.com", "antigravity.google", "antigravity.google.com"]
    case .grok: return ["auth.x.ai", "accounts.x.ai", "grok.com"]
    }
  }
}
