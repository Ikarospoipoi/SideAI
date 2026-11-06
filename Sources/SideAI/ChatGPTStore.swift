import AppKit
import Foundation
import SideAICore

extension SessionStore {
  func signInChatGPT(_ profile: APIProfile? = nil) {
    guard !chatgptSigningIn, !isBusy else { return }
    chatgptSigningIn = true; chatgptLoginStatus = "正在准备官方登录…"
    if settings.chatgptHostID == nil { settings.chatgptHostID = "urn:uuid:" + UUID().uuidString.lowercased(); saveNow() }
    let host = settings.chatgptHostID!
    chatgptLoginTask = Task {
      let listener = OAuthLoopback(), http = ChatGPTAuthHTTP()
      let timeout = Task { try? await Task.sleep(nanoseconds: 300_000_000_000); if !Task.isCancelled { listener.cancel() } }
      defer { timeout.cancel(); listener.cancel(); http.close(); chatgptSigningIn = false; chatgptLoginTask = nil }
      do {
        let previous = try profile.flatMap { try Credentials.read($0.id) }.flatMap { try JSONDecoder().decode(ChatGPTTokens.self, from: Data($0.utf8)) }
        let port = try await listener.start()
        let attempt = ChatGPTLoginAttempt(hostID: host, port: port, returning: previous)
        listener.prepare(state: attempt.state)
        try Task.checkCancellation()
        guard NSWorkspace.shared.open(attempt.authorizationURL) else { throw ProtocolError.message("无法打开系统浏览器。") }
        chatgptLoginStatus = "等待你在浏览器完成官方授权；尚未连接。"
        let callback = try await listener.callback(state: attempt.state)
        let fields = try attempt.exchangeFields(callback: callback)
        let tokens = try await http.exchange(fields, nonce: attempt.nonce, previous: previous)
        try Task.checkCancellation()
        var next = profile ?? profiles.first(where: { $0.auth == .chatgptPlan && $0.oauthSubject == tokens.subject }) ?? ProviderKind.openai.preset()
        next.authentication = .chatgptPlan; next.oauthClientID = tokens.clientID; next.oauthSubject = tokens.subject
        next.accountLabel = tokens.email; next.name = "GPT · " + tokens.email
        try Credentials.save(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), for: next.id)
        var saved = profiles
        if let i = saved.firstIndex(where: { $0.id == next.id }) { saved[i] = next } else { saved.append(next) }
        settings.apiProfiles = saved; settings.selectedProfileID = next.id
        _ = activate(.api(next)); saveNow()
        chatgptLoginStatus = "已连接"
        switchConnection(.api(next))
        refreshAPIModels(next)
      } catch is CancellationError { chatgptLoginStatus = "登录已取消或超时，原连接保持不变。" }
      catch { chatgptLoginStatus = error.localizedDescription }
    }
  }
  func credential(for profile: APIProfile) async throws -> String {
    guard let value = try Credentials.read(profile.id), !value.isEmpty else { throw ProtocolError.message(profile.auth == .chatgptPlan ? "请重新授权此 ChatGPT 聊天账号。" : "请在设置中保存此连接的 API Key。") }
    if profile.auth == .openRouterOAuth {
      guard profile.normalizedEndpoint == "https://openrouter.ai/api/v1", profile.format == .chatCompletions else { throw ProtocolError.message("OpenRouter 账号与连接配置不匹配。") }
      return value
    }
    guard profile.auth == .chatgptPlan else { return value }
    let tokens = try JSONDecoder().decode(ChatGPTTokens.self, from: Data(value.utf8))
    guard tokens.clientID == profile.oauthClientID, tokens.subject == profile.oauthSubject,
          profile.normalizedEndpoint == "https://api.openai.com/v1", profile.format == .responses else { throw ProtocolError.message("ChatGPT 账号与连接配置不匹配。") }
    if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
    if let refreshing = chatgptRefreshTasks[profile.id] { return try await refreshing.value }
    let task = Task { @MainActor in
      let http = ChatGPTAuthHTTP(); defer { http.close() }
      guard !tokens.refreshToken.isEmpty else { throw ProtocolError.message("ChatGPT 登录已过期，请重新授权。") }
      let next = try await http.exchange(["grant_type": "refresh_token", "client_id": tokens.clientID,
        "refresh_token": tokens.refreshToken, "resource": "https://api.openai.com/v1"], nonce: nil, previous: tokens)
      try Credentials.save(String(decoding: JSONEncoder().encode(next), as: UTF8.self), for: profile.id, allowInteraction: false)
      return next.accessToken
    }
    chatgptRefreshTasks[profile.id] = task
    defer { chatgptRefreshTasks[profile.id] = nil }
    return try await task.value
  }
}
