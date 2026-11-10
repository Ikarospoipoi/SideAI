import AppKit
import SideAICore

extension SessionStore {
  func codexEnvironment(_ path: String) throws -> [String: String]? {
    settings.isolatedAgentLogin == true ? try RuntimeEnvironment.isolated(path: path, key: "CODEX_HOME", name: "codex", root: persistence.directory) : nil
  }
  func claudeEnvironment(_ path: String) throws -> [String: String]? {
    settings.isolatedAgentLogin == true ? try RuntimeEnvironment.isolated(path: path, key: "CLAUDE_CONFIG_DIR", name: "claude", root: persistence.directory) : nil
  }
  func cancelAccountLogin() {
    accountLoginTask?.cancel(); accountLoginProcess?.cancel(); accountLoginClient?.stop()
    accountLoginURL = nil
  }
  private func loginOutput(_ text: String, hosts: Set<String>, open: Bool) {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let url = match.url, url.scheme == "https", let host = url.host, hosts.contains(host), accountLoginURL == nil else { continue }
      accountLoginURL = url
      accountLoginStatus = "请在官方页面完成登录，完成后会自动返回。"
      if open { NSWorkspace.shared.open(url) }
    }
    if let range = text.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) {
      accountLoginStatus = "请在官方页面输入验证码：" + text[range]
    }
  }
  private func runtimePath(_ runtime: AccountRuntime) async throws -> String {
    if let path = RuntimeEnvironment.find(runtime.executable) { return path }
    if runtime == .gemini {
      accountLoginStatus = "正在准备 Gemini，首次使用可能需要几分钟…"
      let installer = LoginProcess(); accountLoginProcess = installer
      return try await AntigravityInstaller.install(using: installer)
    }
    guard let package = runtime.npmPackage, let npm = RuntimeEnvironment.find("npm") else { throw ProtocolError.message("需要先安装 Node.js 才能使用这个官方客户端。请安装后重试。") }
    accountLoginStatus = "正在准备 \(runtime.name)，首次使用可能需要一分钟…"
    let installer = LoginProcess(); accountLoginProcess = installer
    try await installer.run(path: npm, arguments: ["install", "--prefix", RuntimeEnvironment.root.appendingPathComponent("Runtimes").path, "--no-audit", "--no-fund", package],
      environment: ClaudeCodeClient.environment(path: npm), cwd: scratch)
    guard let path = RuntimeEnvironment.find(runtime.executable) else { throw ProtocolError.message("客户端安装未完成，请重试。") }
    return path
  }
  func signInRuntime(_ runtime: AccountRuntime, business: Bool = false) {
    guard !isBusy, !chatgptSigningIn else { return }
    accountSigningIn = runtime.name; accountLoginStatus = "正在打开官方登录…"; accountLoginURL = nil
    accountLoginTask = Task {
      defer { accountSigningIn = nil; accountLoginTask = nil; accountLoginProcess = nil; accountLoginClient = nil; accountLoginURL = nil }
      let client = AccountClient(root: persistence.directory); accountLoginClient = client; defer { client.stop() }
      do {
        let path = try await runtimePath(runtime)
        let cwd = try RuntimeEnvironment.prepare(runtime, root: persistence.directory)
        if runtime != .gemini {
          let login = LoginProcess(); accountLoginProcess = login
          try await login.run(path: path, arguments: runtime == .grok ? ["login", "--oauth"] : ["login"], environment: RuntimeEnvironment.isolated(path: path, key: runtime.environmentKey, name: runtime.rawValue, root: persistence.directory), cwd: cwd) { [weak self] text in
            Task { @MainActor in self?.loginOutput(text, hosts: runtime.loginHosts, open: runtime == .kimi) }
          }
        }
        client.onDiagnostic = { [weak self] text in self?.loginOutput(text, hosts: runtime.loginHosts, open: false) }
        let info = try await client.start(runtime: runtime, path: path)
        let method = runtime == .gemini && business ? "oauth-business" : runtime.authMethod
        guard info["authMethods"].array.contains(where: { $0["id"].text == method }) else { throw ProtocolError.message("官方客户端没有提供预期的账号登录方式，请检查版本。") }
        if runtime != .kimi { _ = try await client.request("authenticate", .object(["methodId": .string(method)]), timeout: 300) }
        let session = try await client.newSession(runtime)
        try Task.checkCancellation()
        accountModels[runtime] = AccountClient.models(session)
        var connected = settings.connectedRuntimes ?? []; if !connected.contains(runtime) { connected.append(runtime) }; settings.connectedRuntimes = connected
        accountLoginStatus = "\(runtime.name) 已连接"; saveNow()
        switchConnection(runtime.route)
      } catch is CancellationError { accountLoginStatus = "已取消登录。" }
      catch { accountLoginStatus = error.localizedDescription }
    }
  }
  func signInAgent(_ route: ConnectionRoute, console: Bool = false) {
    guard !isBusy, !chatgptSigningIn else { return }
    accountSigningIn = route.name; accountLoginStatus = "正在打开官方登录…"; accountLoginURL = nil
    settings.isolatedAgentLogin = true
    accountLoginTask = Task {
      defer { accountSigningIn = nil; accountLoginTask = nil; accountLoginProcess = nil; accountLoginURL = nil }
      do {
        if route.backend == .claude {
          guard let path = ClaudeCodeClient.findCLI(custom: settings.claudePath ?? "") else { throw ProtocolError.message("请先安装官方 Claude Code，然后重试。") }
          let login = LoginProcess(); accountLoginProcess = login
          try await login.run(path: path, arguments: ["auth", "login"] + (console ? ["--console"] : []), environment: claudeEnvironment(path)!, cwd: scratch) { [weak self] text in
            Task { @MainActor in self?.loginOutput(text, hosts: ["claude.ai", "platform.claude.com", "console.anthropic.com"], open: false) }
          }
          let status = try await ClaudeCodeClient.authStatus(path: path, environment: claudeEnvironment(path))
          guard status["loggedIn"].bool else { throw ProtocolError.message("登录未完成，请重试。") }
          claudeReady = true; claudeStatus = "已登录"
        } else {
          guard let path = CodexAppServerClient.findCLI(custom: settings.cliPath) else { throw ProtocolError.message("请先安装官方 Codex，然后重试。") }
          _ = try await client.connect(path: path, cwd: scratch, environment: codexEnvironment(path))
          let login = try await client.request("account/login/start", .object(["type": .string("chatgpt")]))
          guard let url = URL(string: login["authUrl"].text), url.scheme == "https", url.host == "auth.openai.com" else { throw ProtocolError.message("官方登录地址无效。") }
          accountLoginURL = url; accountLoginStatus = "请在官方页面完成登录，完成后会自动返回。"; NSWorkspace.shared.open(url)
          let deadline = Date().addingTimeInterval(300)
          var loggedIn = false
          while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let status = try await client.request("account/read", .object(["refreshToken": .bool(false)]))
            if status["account"] != .null { loggedIn = true; break }
          }
          guard loggedIn else { throw ProtocolError.message("登录等待超时，请重试。") }
          ready = true; connection = "已连接"; await refreshCodexModels()
        }
        try Task.checkCancellation()
        var agents = settings.connectedAgentIDs ?? routes.filter { $0.workspace == .agent }.map(\.id)
        if !agents.contains(route.id) { agents.append(route.id) }; settings.connectedAgentIDs = agents
        settings.hiddenAgentIDs?.removeAll { $0 == route.id }
        accountLoginStatus = route.name + " 已连接"; saveNow(); switchConnection(route)
      } catch is CancellationError { if route.backend == .codex { client.stop(); ready = false }; accountLoginStatus = "已取消登录。" }
      catch { accountLoginStatus = error.localizedDescription }
    }
  }
  func refreshAccountModels(_ runtime: AccountRuntime) {
    guard !isBusy else { return }
    guard accountModelTasks[runtime] == nil else { return }
    accountModelTasks[runtime] = Task {
      let client = AccountClient(root: persistence.directory); defer { client.stop(); accountModelTasks[runtime] = nil }
      do {
        guard let path = RuntimeEnvironment.find(runtime.executable) else { throw ProtocolError.message("找不到官方客户端，请重新登录。") }
        _ = try await client.start(runtime: runtime, path: path)
        let session = try await client.newSession(runtime)
        try Task.checkCancellation()
        guard (settings.connectedRuntimes ?? []).contains(runtime) else { return }
        accountModels[runtime] = AccountClient.models(session); connectionNotice = "模型已更新"
        if let id = selectedID, selected?.accountRuntime == runtime, selected?.modelID == nil { mutate(id) { $0.modelID = accountModels[runtime]?.first?.id } }
      } catch is CancellationError { }
      catch { connectionNotice = error.localizedDescription }
    }
  }
  func sendAccount(_ c: Conversation, memory: MemoryContext? = nil) {
    guard let runtime = c.accountRuntime, let path = RuntimeEnvironment.find(runtime.executable) else { banner = "请重新连接账号。"; return }
    preparingAPI = true
    let client = AccountClient(root: persistence.directory); accountClients[c.id] = client
    accountTasks[c.id] = Task {
      var responseID: String?
      defer { client.stop(); accountClients[c.id] = nil; accountTasks[c.id] = nil; preparingAPI = false; saveNow() }
      do {
        let info = try await client.start(runtime: runtime, path: path)
        if (!c.images.isEmpty || c.items.contains { !($0.attachments ?? []).isEmpty }) && !info["agentCapabilities"]["promptCapabilities"]["image"].bool { throw ProtocolError.message("这个官方客户端不支持图片，请使用它的 API 连接。") }
        let session = try await client.newSession(runtime)
        let sessionID = session["sessionId"].text
        guard !sessionID.isEmpty else { throw ProtocolError.message("无法创建聊天，请重新登录。") }
        accountModels[runtime] = AccountClient.models(session)
        if let model = c.modelID, !model.isEmpty {
          try await client.setModel(model, session: session)
        }
        let prompt = try AccountClient.prompt(c, memory: memory)
        try Task.checkCancellation()
        let id = UUID().uuidString; responseID = id
        mutate(c.id) {
          $0.items += [TimelineItem(id: id, kind: "agentMessage", text: "", status: "inProgress")]
          $0.status = .running; $0.error = nil
          if $0.title == "新会话" { $0.title = c.draft.isEmpty ? "图片会话" : String(c.draft.prefix(24)) }
        }
        preparingAPI = false
        var answer = ""
        client.onText = { [weak self] text in answer = text; self?.mutate(c.id) { $0.upsert(TimelineItem(id: id, kind: "agentMessage", text: text, status: "inProgress")) } }
        let result = try await client.request("session/prompt", .object(["sessionId": .string(sessionID), "prompt": prompt]), timeout: 300)
        try Task.checkCancellation()
        guard result["stopReason"].text == "end_turn", !answer.isEmpty else { throw ProtocolError.message("回复未完整结束，请重试。") }
        mutate(c.id) { $0.upsert(TimelineItem(id: id, kind: "agentMessage", text: answer)); $0.status = .completed; $0.updatedAt = Date() }; onCompletion?()
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        if let id = responseID {
          mutate(c.id) {
            $0.status = cancelled ? .interrupted : .failed; $0.error = cancelled ? nil : error.localizedDescription
            if let i = $0.items.firstIndex(where: { $0.id == id }) { $0.items[i].status = cancelled ? "interrupted" : "failed" }
          }
        } else { mutate(c.id) { $0.status = cancelled ? .interrupted : .failed; $0.error = cancelled ? nil : error.localizedDescription } }
      }
    }
  }
}
