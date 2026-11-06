import AppKit
import SideAICore

extension SessionStore {
  func authorizeCredential(_ profile: APIProfile) {
    guard !isBusy, !credentialAuthorizing else { return }
    credentialAuthorizing = true
    connectionNotice = "等待 macOS 钥匙串授权。请在系统窗口操作；SideAI 不收集你的系统密码。"
    Task {
      defer { credentialAuthorizing = false }
      do {
        let found = try await Task.detached { try Credentials.read(profile.id, allowInteraction: true) != nil }.value
        connectionNotice = found ? "钥匙串访问已授权。可以回到会话发送；尚未向模型发出请求。" : "没有保存的凭据，请编辑连接输入 API Key，或重新授权官方账号。"
      } catch { connectionNotice = error.localizedDescription }
    }
  }
  func removeConnection(_ route: ConnectionRoute, deleteCredential: (UUID) throws -> Void = Credentials.delete) throws {
    guard !isBusy, !chatgptSigningIn, !connecting else { throw ProtocolError.message("请等待正在进行的请求、授权或连接完成后再删除。") }
    guard routes.contains(where: { $0.id == route.id }) else { return }
    if let id = route.profileID, let profile = profiles.first(where: { $0.id == id }) {
      try deleteCredential(id) // Fail atomically: leave configuration intact if Keychain refuses deletion.
      chatgptRefreshTasks[id]?.cancel(); chatgptRefreshTasks[id] = nil
      var removed = settings.removedAPIProfiles ?? []; removed.removeAll { $0.id == id }; removed.append(profile)
      settings.removedAPIProfiles = removed; settings.apiProfiles = profiles.filter { $0.id != id }
      apiModels[id] = nil; apiConnectionStatus[id] = nil
      if settings.selectedProfileID == id { settings.selectedProfileID = nil }
    } else if route.id == ConnectionRoute.claudeChat.id {
      settings.claudeChatEnabled = false
    } else {
      var hidden = settings.hiddenAgentIDs ?? []; if !hidden.contains(route.id) { hidden.append(route.id) }; settings.hiddenAgentIDs = hidden
      if route.backend == .codex { client.stop(); ready = false; connection = "连接已移除" }
      if route.backend == .claude { claudeReady = false; claudeStatus = "连接已移除" }
    }
    settings.activeRoutes = (settings.activeRoutes ?? [:]).filter { $0.value != route.id }
    if selected?.routeID == route.id { selectedID = nil }
    connectionNotice = "连接已移除，历史与草稿保留。官方账号没有被注销或撤销授权。"
    saveNow()
  }
  func restoreConnection(_ routeID: String) throws {
    guard !isBusy, !chatgptSigningIn else { throw ProtocolError.message("请等待当前操作完成。") }
    if let profile = (settings.removedAPIProfiles ?? []).first(where: { $0.routeID == routeID }) {
      guard !profiles.contains(where: { profile.duplicates($0) }) else { throw ProtocolError.message("已有相同连接，请先处理重复配置。") }
      settings.apiProfiles = profiles + [profile]
      settings.removedAPIProfiles?.removeAll { $0.id == profile.id }
      connectionNotice = "已恢复配置和原历史关联；请重新填写密钥或重新授权。"
    } else if routeID == ConnectionRoute.claudeChat.id {
      settings.claudeChatEnabled = true
      connectionNotice = "已恢复 Claude 聊天入口，进入后检测本机官方登录。"
    } else {
      settings.hiddenAgentIDs?.removeAll { $0 == routeID }
      if settings.connectedAgentIDs != nil && !settings.connectedAgentIDs!.contains(routeID) { settings.connectedAgentIDs?.append(routeID) }
      connectionNotice = "已恢复 Agent 入口；进入后重新检测官方登录。"
    }
    if let route = routes.first(where: { $0.id == routeID }) { _ = activate(route) }
    saveNow()
  }
}
