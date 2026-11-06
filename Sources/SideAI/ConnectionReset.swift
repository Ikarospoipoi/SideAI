import Foundation
import SideAICore

extension SessionStore {
  func disconnectConnection(_ route: ConnectionRoute) async throws {
    guard !isBusy, !chatgptSigningIn else { throw ProtocolError.message("请先完成或取消当前操作。") }
    if let runtime = AccountRuntime.allCases.first(where: { $0.route.id == route.id }) {
      accountModelTasks.removeValue(forKey: runtime)?.cancel()
      try await clearPrivateLogin(runtime.rawValue)
      settings.connectedRuntimes?.removeAll { $0 == runtime }; accountModels[runtime] = nil
      settings.activeRoutes = (settings.activeRoutes ?? [:]).filter { $0.value != route.id }
      if selected?.routeID == route.id { selectedID = nil }; saveNow(); return
    }
    if route.workspace == .agent, settings.isolatedAgentLogin == true {
      try await clearPrivateLogin(route.backend == .codex ? "codex" : "claude")
    }
    try removeConnection(route)
    settings.connectedAgentIDs?.removeAll { $0 == route.id }; saveNow()
  }
  /// Only private SideAI runtime directories are affected. Never logs out the user's global CLI.
  private func clearPrivateLogin(_ name: String) async throws {
    let home = persistence.directory.appendingPathComponent("Accounts/" + name)
    guard FileManager.default.fileExists(atPath: home.path) else { return }
    if name == "gemini", let path = RuntimeEnvironment.find("agy") {
      let account = AccountClient(root: persistence.directory); defer { account.stop() }
      let info = try await account.start(runtime: .gemini, path: path)
      guard info["agentCapabilities"]["auth"]["logout"] != .null else { throw ProtocolError.message("官方客户端未提供退出登录接口，请检查版本。") }
      _ = try await account.request("logout", .object([:]))
    }
    if name == "codex" { client.stop(); ready = false }
    if name == "claude", let path = ClaudeCodeClient.findCLI(custom: settings.claudePath ?? "") {
      try await LoginProcess().run(path: path, arguments: ["auth", "logout"],
        environment: RuntimeEnvironment.isolated(path: path, key: "CLAUDE_CONFIG_DIR", name: "claude", root: persistence.directory), cwd: scratch)
      claudeReady = false
    }
    // Credentials are private to this application. Local conversation content is in state.json.
    try FileManager.default.removeItem(at: home)
  }
  func resetOnboarding(deleteCredential: (UUID) throws -> Void = Credentials.delete) async throws {
    guard !isBusy, !chatgptSigningIn, !connecting else { throw ProtocolError.message("请先完成或取消当前操作。") }
    let backup = persistence.directory.appendingPathComponent("Backups/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
    try Persistence(directory: backup).save(Snapshot(settings: settings, conversations: state.conversations, selectedID: selectedID))
    for profile in profiles + (settings.removedAPIProfiles ?? []) { try deleteCredential(profile.id) }
    for task in accountModelTasks.values { task.cancel() }; accountModelTasks.removeAll()
    client.stop(); ready = false; claudeReady = false
    if settings.isolatedAgentLogin == true {
      for name in ["codex", "claude"] + AccountRuntime.allCases.map(\.rawValue) { try await clearPrivateLogin(name) }
    } else {
      // New account runtimes are always isolated, even when legacy agents shared a home.
      for runtime in AccountRuntime.allCases { try await clearPrivateLogin(runtime.rawValue) }
    }
    for task in chatgptRefreshTasks.values { task.cancel() }; chatgptRefreshTasks.removeAll()
    settings = AppSettings(); settings.connectedAgentIDs = []; settings.connectedRuntimes = []; settings.isolatedAgentLogin = true
    settings.claudeChatEnabled = false; settings.workspaceMode = .chat; settings.routingVersion = 2; settings.apiProfiles = []
    state = EventState(conversations: []); selectedID = nil
    apiModels.removeAll(); accountModels.removeAll(); apiConnectionStatus.removeAll(); restored.removeAll()
    accountLoginStatus = ""; connectionNotice = ""; banner = nil; connection = "未连接"; claudeStatus = "未登录"
    chatgptLoginStatus = "可新增官方授权，或使用下方已保存的连接。"
    saveNow(); onSettingsChanged?()
  }
}
