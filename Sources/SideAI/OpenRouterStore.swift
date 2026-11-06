import AppKit
import SideAICore

extension SessionStore {
  func signInOpenRouter(_ existing: APIProfile? = nil) {
    guard !isBusy, !chatgptSigningIn else { return }
    accountSigningIn = "OpenRouter"; accountLoginStatus = "正在打开官方登录…"
    accountLoginTask = Task {
      let listener = OAuthLoopback(), http = ChatGPTAuthHTTP()
      let timeout = Task { try? await Task.sleep(nanoseconds: 300_000_000_000); if !Task.isCancelled { listener.cancel() } }
      defer { timeout.cancel(); listener.cancel(); http.close(); accountSigningIn = nil; accountLoginURL = nil; accountLoginTask = nil }
      do {
        let attempt = OpenRouterLoginAttempt(port: try await listener.start())
        listener.prepare(state: attempt.state)
        accountLoginURL = attempt.authorizationURL
        guard NSWorkspace.shared.open(attempt.authorizationURL) else { throw ProtocolError.message("无法打开浏览器") }
        accountLoginStatus = "请在官方页面完成登录，完成后会自动返回。"
        let callback = try await listener.callback(state: attempt.state)
        let result = try await http.request(URL(string: "https://openrouter.ai/api/v1/auth/keys")!, json: attempt.exchangeBody(callback))
        guard let key = result["key"].string, !key.isEmpty else { throw ProtocolError.message("官方授权未返回有效凭据") }
        try Task.checkCancellation()
        var profile = existing ?? profiles.first { $0.auth == .openRouterOAuth } ?? ProviderKind.openrouter.preset()
        profile.authentication = .openRouterOAuth; profile.name = "OpenRouter"
        profile.defaultModel = "openrouter/auto"
        try Credentials.save(key, for: profile.id)
        var next = profiles; next.removeAll { $0.id == profile.id }; next.append(profile); settings.apiProfiles = next
        saveNow(); switchConnection(.api(profile)); accountLoginStatus = "OpenRouter 已连接"
        refreshAPIModels(profile)
      } catch is CancellationError { accountLoginStatus = "已取消登录。" }
      catch { accountLoginStatus = error.localizedDescription }
    }
  }
}
