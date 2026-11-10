import AppKit
import SideAICore

extension SessionStore {
  var routes: [ConnectionRoute] { [.codex, .claude].filter { !(settings.hiddenAgentIDs ?? []).contains($0.id) && (settings.connectedAgentIDs == nil || settings.connectedAgentIDs!.contains($0.id)) } + (settings.claudeChatEnabled == true ? [.claudeChat] : []) + (settings.connectedRuntimes ?? []).map(\.route) + profiles.map(ConnectionRoute.api) }
  var currentRoute: ConnectionRoute { route(for: selected) }
  func route(for conversation: Conversation?) -> ConnectionRoute {
    guard let c = conversation else { return .codex }
    if c.engine == .chatgptArchive { return .archive }
    if let route = routes.first(where: { $0.id == c.routeID }) { return route }
    let removed = (settings.removedAPIProfiles ?? []).first { $0.id == c.profileID }.map(ConnectionRoute.api)
      ?? (AccountRuntime.allCases.map(\.route) + [.codex, .claude, .claudeChat]).first { $0.id == c.routeID }
    if let removed { return ConnectionRoute(id: removed.id, name: removed.name + "（已移除）", provider: removed.provider, backend: removed.backend, profileID: removed.profileID, groupID: removed.groupID) }
    return ConnectionRoute(id: c.routeID, name: "缺少 API 配置", provider: .custom, backend: .api)
  }
  func isRouteActive(_ route: ConnectionRoute) -> Bool { routes.contains(where: { $0.id == route.id }) && ConnectionPolicy.isActive(route, in: settings.activeRoutes ?? [:]) }
  var workspace: WorkspaceMode { settings.workspaceMode ?? .chat }
  var workspaceRoutes: [ConnectionRoute] { routes.filter { $0.workspace == workspace } }
  func switchWorkspace(_ mode: WorkspaceMode) {
    rememberCurrentConversation()
    settings.workspaceMode = mode
    if let id = settings.lastConversationByWorkspace?[mode.rawValue],
       let c = state.conversations.first(where: { $0.id == id && $0.workspace == mode && !$0.archived }) {
      select(c.id)
    } else if let c = state.conversations.filter({ $0.workspace == mode && !$0.archived }).max(by: { $0.updatedAt < $1.updatedAt }) {
      select(c.id)
    } else { selectedID = nil }
    saveSoon()
  }
  func initializeRoutes() {
    if settings.routingVersion != 2 {
      var active = [String: String]()
      for route in routes {
        if active[route.selectionGroup] == nil || settings.activeRoutes?[route.selectionGroup] == route.id || settings.activeRoutes?[route.groupID] == route.id {
          active = ConnectionPolicy.activated(route, in: active)
        }
      }
      settings.activeRoutes = active; settings.routingVersion = 2
    }
    // Leave legacy chats on their original backend; never reuse agent sessions as API conversations.
    for c in state.conversations where !c.archived {
      if settings.lastConversationByWorkspace?[c.workspace.rawValue] == nil {
        var remembered = settings.lastConversationByWorkspace ?? [:]
        remembered[c.workspace.rawValue] = c.id; settings.lastConversationByWorkspace = remembered
      }
    }
    settings.activeRoutes = (settings.activeRoutes ?? [:]).filter { entry in routes.contains { $0.id == entry.value } }
    if settings.workspaceMode == nil {
      rememberCurrentConversation()
      settings.workspaceMode = .chat
      selectedID = state.conversations.filter { $0.workspace == .chat && !$0.archived }.max { $0.updatedAt < $1.updatedAt }?.id
    }
    if let c = selected, c.workspace != workspace { selectedID = nil }
    rememberCurrentConversation()
  }
  func rememberCurrentConversation() {
    guard let c = selected else { return }
    var remembered = settings.lastConversationByRoute ?? [:]
    remembered[c.routeID] = c.id
    settings.lastConversationByRoute = remembered
    var spaces = settings.lastConversationByWorkspace ?? [:]
    spaces[c.workspace.rawValue] = c.id; settings.lastConversationByWorkspace = spaces
  }
  @discardableResult func activate(_ route: ConnectionRoute) -> Bool {
    guard route.backend != .chatgptArchive, routes.contains(where: { $0.id == route.id }) else { banner = "连接已移除。请在连接管理恢复配置。"; return false }
    let old = settings.activeRoutes?[route.selectionGroup]
    if old != route.id, state.conversations.contains(where: { $0.status.isActive && self.route(for: $0).selectionGroup == route.selectionGroup }) {
      banner = "该服务商还有任务运行中，请先停止或等待完成再更换连接。"; return false
    }
    settings.activeRoutes = ConnectionPolicy.activated(route, in: settings.activeRoutes ?? [:]); saveSoon()
    return true
  }
  func switchConnection(_ route: ConnectionRoute) {
    guard activate(route) else { return }
    rememberCurrentConversation()
    settings.workspaceMode = route.workspace
    banner = nil
    if let remembered = settings.lastConversationByRoute?[route.id], let c = state.conversations.first(where: { $0.id == remembered && $0.routeID == route.id && !$0.archived }) { select(c.id) }
    else if let c = state.conversations.filter({ $0.routeID == route.id && !$0.archived }).max(by: { $0.updatedAt < $1.updatedAt }) { select(c.id) }
    else { newConversation(route: route) }
    if route.backend == .claude { refreshClaudeStatus() }
    if let runtime = AccountRuntime.allCases.first(where: { $0.route.id == route.id }), accountModels[runtime] == nil { refreshAccountModels(runtime) }
    if route.backend == .codex && !ready { connect() }
    onRouteOpen?()
  }
  func newConversation(route: ConnectionRoute) {
    guard activate(route) else { return }
    rememberCurrentConversation(); settings.workspaceMode = route.workspace
    var c = Conversation(cwd: scratch.path); c.backend = route.backend; c.profileID = route.profileID
    switch route.backend {
    case .accountRuntime: c.accountRuntime = AccountRuntime.allCases.first { $0.route.id == route.id }; c.modelID = c.accountRuntime.flatMap { accountModels[$0]?.first?.id }
    case .codex: c.modelID = codexModels.first?.id
    case .claude:
      c.modelID = "sonnet"; c.reasoningEffort = "medium"
      c.claudeChatOnly = route.id == ConnectionRoute.claudeChat.id
      c.claudeAgentEnabled = c.claudeChatOnly != true
    case .api: c.modelID = profiles.first { $0.id == route.profileID }?.defaultModel
    case .chatgptArchive: return
    }
    state.conversations.append(c); selectedID = c.id; rememberCurrentConversation(); saveSoon()
  }
  var currentConnectionStatus: String {
    let r = currentRoute
    guard r.backend != .chatgptArchive else { return "只读导入记录" }
    guard isRouteActive(r) else { return "此通道未启用" }
    switch r.backend {
    case .accountRuntime: return "已连接"
    case .codex: return connection
    case .claude: return claudeStatus
    case .api: return apiConnectionStatus[r.profileID ?? UUID()] ?? "API 已配置 · 发送时验证"
    case .chatgptArchive: return "只读"
    }
  }
  var currentConnectionReady: Bool {
    guard isRouteActive(currentRoute) else { return false }
    switch currentRoute.backend { case .accountRuntime: return selected?.accountRuntime != nil; case .codex: return ready; case .claude: return claudeReady; case .api: return selectedProfile != nil; case .chatgptArchive: return false }
  }
  func refreshCurrentModels() {
    switch selected?.engine {
    case .accountRuntime: if let runtime = selected?.accountRuntime { refreshAccountModels(runtime) }
    case .claude: refreshClaudeStatus()
    case .api: if let profile = selectedProfile { refreshAPIModels(profile) }
    default: Task { await refreshCodexModels() }
    }
  }
  func refreshClaudeStatus() {
    guard !claudeChecking else { return }
    guard let path = ClaudeCodeClient.findCLI(custom: settings.claudePath ?? "") else { claudeReady = false; claudeStatus = "未找到 Claude Code · 请在设置选择 CLI"; return }
    claudeChecking = true
    Task {
      defer { claudeChecking = false }
      do {
        let status = try await ClaudeCodeClient.authStatus(path: path, environment: claudeEnvironment(path))
        claudeReady = status["loggedIn"].bool
        claudeStatus = claudeReady ? (status["authMethod"].text == "claude.ai" ? "已登录 Claude 账户 · 网络待请求验证" : "Claude CLI 已登录 · 使用其配置的计费方式") : "Claude 未登录 · 请运行官方登录命令"
      } catch { claudeReady = false; claudeStatus = error.localizedDescription }
    }
  }
  func sendClaude(_ original: Conversation, memory: MemoryContext? = nil) {
    guard claudeReady, let path = ClaudeCodeClient.findCLI(custom: settings.claudePath ?? "") else { banner = "请先在设置中检测 Claude Code 登录。"; return }
    var c = original
    if c.claudeUsesTools && c.mode == .project && c.cwd == scratch.path { banner = "请先选择项目目录。"; return }
    if c.claudeSessionID == nil { c.claudeSessionID = UUID().uuidString.lowercased() }
    do {
      let args = try ClaudeProtocol.arguments(conversation: c)
      var input = try JSONEncoder().encode(ClaudeProtocol.input(c, memory: memory)); input.append(10)
      let cwd = c.claudeUsesTools ? URL(fileURLWithPath: c.cwd) : scratch.appendingPathComponent("Claude", isDirectory: true)
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let responseID = UUID().uuidString
      mutate(c.id) {
        $0.claudeSessionID = c.claudeSessionID
        $0.items.append(TimelineItem(id: responseID, kind: "agentMessage", text: "", status: "inProgress"))
        $0.status = .running; $0.error = nil; $0.updatedAt = Date()
        if $0.title == "新会话" { $0.title = c.draft.isEmpty ? "图片会话" : String(c.draft.prefix(24)) }
      }
      saveNow()
      let cli = ClaudeCodeClient(); claudeClients[c.id] = cli
      let accumulator = ClaudeAccumulator(allowedTools: ClaudePermissions.tools(for: c))
      let id = c.id
      claudeTasks[id] = Task {
        defer { claudeClients[id] = nil; claudeTasks[id] = nil; claudeApprovals.removeAll { $0.conversationID == id }; saveNow() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 300_000_000_000); if !Task.isCancelled { accumulator.fail("Claude 请求超过 5 分钟，已停止；不会自动重发。"); cli.cancel() } }
        defer { timeout.cancel() }
        do {
          let code = try await cli.run(path: path, arguments: args, input: input, cwd: cwd, effort: c.reasoningEffort, interactive: c.claudeUsesTools, environment: claudeEnvironment(path)) { [weak self] event in
            accumulator.receive(event)
            let snapshot = accumulator.snapshot()
            if snapshot.error != nil { cli.cancel() }
            Task { @MainActor in
              guard let self, let current = self.state.conversations.first(where: { $0.id == id }), current.status.isActive else { return }
              if event["type"].text == "control_request" {
                if let approval = ClaudePermissions.approval(event: event, conversation: c) {
                  if !self.claudeApprovals.contains(where: { $0.id == approval.id }) { self.claudeApprovals.append(approval) }
                  self.mutate(id) { $0.status = .awaitingApproval }; self.onAttention?()
                } else { cli.sendControl(ClaudePermissions.reply(id: event["request_id"].text, input: .object([:]), allow: false)) }
              }
              if event["type"].text == "control_cancel_request" { self.claudeApprovals.removeAll { $0.id == event["request_id"].text } }
              if event["type"].text == "assistant" {
                for tool in event["message"]["content"].array where tool["type"].text == "tool_use" {
                  self.mutate(id) { $0.upsert(TimelineItem(id: tool["id"].text, kind: "toolCall", text: tool["name"].text, detail: tool["input"].pretty)) }
                }
              }
              self.mutate(id) {
                $0.upsert(TimelineItem(id: responseID, kind: "agentMessage", text: snapshot.state.text, status: "inProgress"))
                if snapshot.state.started { $0.claudeHasSession = true }
                $0.resolvedModel = snapshot.state.model ?? $0.resolvedModel
              }
            }
          }
          let result = accumulator.snapshot()
          if let error = result.error { throw ProtocolError.message(error) }
          guard code == 0, result.state.completed, !result.state.text.isEmpty else { throw ProtocolError.message("Claude 未返回完整结束事件（退出码 \(code)）。已保留会话，不会自动重发。") }
          mutate(id) { $0.upsert(TimelineItem(id: responseID, kind: "agentMessage", text: result.state.text)); $0.status = .completed; $0.claudeHasSession = true; $0.resolvedModel = result.state.model }
          claudeStatus = "Claude 已连接 · 上次请求成功"; onCompletion?()
        } catch {
          let result = accumulator.snapshot()
          let cancelled = Task.isCancelled || (error is CancellationError && result.error == nil)
          mutate(id) {
            $0.status = cancelled ? .interrupted : .failed
            $0.error = cancelled ? nil : result.error ?? error.localizedDescription
            $0.claudeHasSession = result.state.started || c.claudeHasSession == true
            if let i = $0.items.firstIndex(where: { $0.id == responseID }) { $0.items[i].status = cancelled ? "interrupted" : "failed"; $0.items[i].text = result.state.text }
          }
          if !cancelled { claudeStatus = "已登录，但上次请求失败 · 查看会话错误" }
        }
      }
    } catch { banner = error.localizedDescription }
  }
}
final class ClaudeAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var state: ClaudeStreamState
  init(allowedTools: [String] = []) { state = ClaudeStreamState(allowedTools: allowedTools) }
  private var error: String?
  func receive(_ event: JSON) { lock.lock(); defer { lock.unlock() }; do { try state.receive(event) } catch { self.error = error.localizedDescription } }
  func fail(_ text: String) { lock.lock(); defer { lock.unlock() }; error = text }
  func snapshot() -> (state: ClaudeStreamState, error: String?) { lock.lock(); defer { lock.unlock() }; return (state, error) }
}
