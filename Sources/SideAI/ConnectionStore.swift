import AppKit
import SideAICore
import UniformTypeIdentifiers

extension SessionStore {
  var profiles: [APIProfile] { settings.apiProfiles ?? [] }
  var selectedProfile: APIProfile? { profiles.first { $0.id == selected?.profileID } }
  var availableModels: [ModelOption] {
    if let runtime = selected?.accountRuntime { return accountModels[runtime] ?? [] }
    if selected?.engine == .claude { return ClaudeProtocol.models }
    guard selected?.engine == .api else { return codexModels }
    return selectedProfile.flatMap { apiModels[$0.id] } ?? []
  }
  var canSend: Bool {
    guard let c = selected, c.canSendContent, !isBusy, !syncing else { return false }
    return currentConnectionReady
  }
  func selectModel(_ model: ModelOption) {
    guard let c = selected, !isBusy else { return }
    mutate(c.id) { $0.modelID = model.id; $0.reasoningEffort = model.defaultEffort }
  }
  func refreshCodexModels() async {
    do {
      var result = [ModelOption](), cursor: JSON = .null
      repeat {
        var p: [String: JSON] = ["limit": .number(100)]
        if cursor != .null { p["cursor"] = cursor }
        let page = try await client.request("model/list", .object(p))
        result += page["data"].array.map(ModelOption.init(codex:)).filter { !$0.id.isEmpty }
        cursor = page["nextCursor"]
      } while cursor != .null
      codexModels = result
    } catch { banner = "模型列表读取失败：\(error.localizedDescription)" }
  }
  func saveProfile(_ profile: APIProfile, key: String) throws {
    guard profile.auth == .apiKey else { throw ProtocolError.message("ChatGPT 账号连接由官方登录管理，请使用重新授权。") }
    guard !isBusy else { throw ProtocolError.message("请等待当前任务结束后再修改连接。") }
    if !key.isEmpty && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ProtocolError.message("API Key 不能只有空格。") }
    _ = try profile.endpoint("models")
    guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProtocolError.message("请填写连接名称") }
    if let duplicate = profiles.first(where: { profile.duplicates($0) }) { throw ProtocolError.message("该地址已配置为「\(duplicate.name)」，请编辑原连接，不必重复添加。") }
    let old = profiles.first { $0.id == profile.id }
    if let old, state.conversations.contains(where: { $0.profileID == profile.id }),
      old.normalizedEndpoint != profile.normalizedEndpoint || old.format != profile.format || old.groupID != profile.groupID || old.auth != profile.auth {
      throw ProtocolError.message("此连接已有会话，不能更换服务地址、协议或服务商。请新增连接，旧会话继续绑定原连接。")
    }
    if let old, old.baseURL != profile.baseURL, key.isEmpty {
      throw ProtocolError.message("API 地址已更改，请重新输入该服务的密钥。")
    }
    if !key.isEmpty { try Credentials.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: profile.id) }
    var next = profiles
    if let i = next.firstIndex(where: { $0.id == profile.id }) { next[i] = profile } else { next.append(profile) }
    settings.apiProfiles = next; settings.selectedProfileID = profile.id
    apiModels[profile.id] = nil
    if settings.activeRoutes?[ConnectionRoute.api(profile).selectionGroup] == nil { settings.activeRoutes = ConnectionPolicy.activated(.api(profile), in: settings.activeRoutes ?? [:]) }
    saveNow()
    connectionNotice = isRouteActive(.api(profile)) ? "已保存并启用；密钥保存在钥匙串。" : "已保存为备用连接。点击启用后再测试，同服务商的其他聊天通道会成为备用，Agent 不受影响。"
  }
  func refreshAPIModels(_ profile: APIProfile) {
    guard isRouteActive(.api(profile)) else { connectionNotice = "请先启用此连接，再测试。"; return }
    guard testingProfiles.insert(profile.id).inserted else { return }
    connectionNotice = "正在连接 \(profile.name)…"
    Task {
      let http = HTTPChatClient()
      defer { http.cancel(); testingProfiles.remove(profile.id) }
      do {
        let key = try await credential(for: profile)
        apiModels[profile.id] = try await http.models(profile: profile, key: key)
        if profile.defaultModel.isEmpty, let model = apiModels[profile.id]?.first {
          if let index = settings.apiProfiles?.firstIndex(where: { $0.id == profile.id }) { settings.apiProfiles?[index].defaultModel = model.id }
          for c in state.conversations where c.profileID == profile.id && (c.modelID ?? "").isEmpty { mutate(c.id) { $0.modelID = model.id } }
          saveSoon()
        }
        connectionNotice = "连接成功 · \(apiModels[profile.id]?.count ?? 0) 个模型"
        apiConnectionStatus[profile.id] = "API 模型列表可达"
      } catch { connectionNotice = error.localizedDescription; apiConnectionStatus[profile.id] = "API 测试失败" }
    }
  }
  func loginDevice() {
    guard isRouteActive(.codex), !isBusy else { connectionNotice = "请先启用 Codex 连接并等待任务结束。"; return }
    Task {
      do {
        let result = try await client.request("account/login/start", .object(["type": .string("chatgptDeviceCode")]))
        let code = result["userCode"].text
        connectionNotice = "设备登录代码：\(code)"
        if let url = URL(string: result["verificationUrl"].text), url.scheme == "https" { loginURL = url; NSWorkspace.shared.open(url) }
      } catch { connectionNotice = error.localizedDescription }
    }
  }
  func loginCodexAPI(_ key: String) {
    guard isRouteActive(.codex), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isBusy else { return }
    Task {
      do {
        _ = try await client.request("account/login/start", .object(["type": .string("apiKey"), "apiKey": .string(key)]))
        connect()
      } catch { connectionNotice = error.localizedDescription.replacingOccurrences(of: key, with: "[redacted]") }
    }
  }
  func sendAPI(_ c: Conversation, memory: MemoryContext? = nil) {
    guard let profile = profiles.first(where: { $0.id == c.profileID }) else { banner = "请在设置中添加 API 连接，并新建该连接的会话。"; return }
    preparingAPI = true
    apiTasks[c.id] = Task {
      defer { preparingAPI = false; apiTasks[c.id] = nil; apiClients[c.id]?.cancel(); apiClients[c.id] = nil; saveNow() }
      var secret = ""
      var responseID: String?
      do {
        secret = try await credential(for: profile)
        try Task.checkCancellation()
        guard profiles.contains(where: { $0.id == profile.id }) else { throw CancellationError() }
        var context = c
        var user = TimelineItem(kind: "userMessage", text: c.draft); user.attachments = c.images
        context.items.append(user)
        let body = try APIRequestBuilder.body(conversation: context, format: profile.format, model: c.modelID ?? profile.defaultModel, memory: memory)
        banner = nil
        let itemID = UUID().uuidString; responseID = itemID
        mutate(c.id) {
          $0.items.append(user); $0.items.append(TimelineItem(id: itemID, kind: "agentMessage", text: "", status: "inProgress"))
          $0.draft = ""; $0.attachments = []; $0.status = .running; $0.error = nil; $0.updatedAt = Date()
          if $0.title == "新会话" { $0.title = c.draft.isEmpty ? "图片会话" : String(c.draft.prefix(24)) }
        }
        preparingAPI = false; saveNow()
        let http = HTTPChatClient(); apiClients[c.id] = http
        let text = try await http.stream(profile: profile, key: secret, body: body) { [weak self] text in
          self?.mutate(c.id) { $0.upsert(TimelineItem(id: itemID, kind: "agentMessage", text: text, status: "inProgress")) }
        }
        try Task.checkCancellation()
        mutate(c.id) { $0.upsert(TimelineItem(id: itemID, kind: "agentMessage", text: text)); $0.status = .completed }
        apiConnectionStatus[profile.id] = "API 已连接 · 上次请求成功"
        onCompletion?()
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        let message = secret.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: secret, with: "[redacted]")
        if let responseID {
          mutate(c.id) {
            $0.status = cancelled ? .interrupted : .failed; $0.error = cancelled ? nil : message
            if let i = $0.items.firstIndex(where: { $0.id == responseID }) { $0.items[i].status = cancelled ? "interrupted" : "failed" }
          }
        } else { banner = cancelled ? "请求已取消，草稿保留。" : message }
      }
    }
  }
  func syncConversations() {
    guard ready, !syncing, !isBusy else { return }
    syncing = true; syncStatus = "正在同步 Codex 会话…"
    Task {
      defer { syncing = false; saveSoon() }
      do {
        var count = 0
        for archived in [false, true] {
          var cursor: JSON = .null
          repeat {
            var params: [String: JSON] = ["limit": .number(100), "archived": .bool(archived), "modelProviders": .array([]),
              "sourceKinds": .array(["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"].map(JSON.string))]
            if cursor != .null { params["cursor"] = cursor }
            let page = try await client.request("thread/list", .object(params))
            for thread in page["data"].array {
              guard let tid = thread["id"].string else { continue }
              count += 1
              if let i = state.conversations.firstIndex(where: { $0.threadID == tid }) {
                if !state.conversations[i].status.isActive {
                  if state.conversations[i].locallyRenamed != true, let title = thread["name"].string, !title.isEmpty { state.conversations[i].title = title }
                  // Local archiving and workspace choices remain local preferences.
                  if state.conversations[i].imported == true { state.conversations[i].updatedAt = Date(timeIntervalSince1970: thread["updatedAt"].numberValue) }
                }
              } else {
                var c = Conversation(cwd: thread["cwd"].string ?? scratch.path)
                c.backend = .codex; c.threadID = tid; c.modelID = thread["model"].string; c.imported = true; c.archived = archived
                let title = thread["name"].string ?? thread["preview"].text
                c.title = title.isEmpty ? "Codex 会话" : String(title.prefix(100))
                c.updatedAt = Date(timeIntervalSince1970: thread["updatedAt"].numberValue)
                state.conversations.append(c)
              }
            }
            cursor = page["nextCursor"]
          } while cursor != .null
        }
        restored.removeAll()
        await restoreSelected()
        syncStatus = "已同步 \(count) 个 Codex 会话 · \(Date().formatted(date: .omitted, time: .shortened))"
      } catch { syncStatus = "同步未完成：\(error.localizedDescription)" }
    }
  }
  func importChatGPT() {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
    panel.message = "选择 ChatGPT 数据导出中的 conversations.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let imported = try ChatGPTImport.parse(Data(contentsOf: url), cwd: scratch.path)
      var added = 0
      for c in imported where !state.conversations.contains(where: { $0.importID == c.importID }) { state.conversations.append(c); added += 1 }
      syncStatus = "已导入 \(added) 个 ChatGPT 会话（重复项已跳过）"; saveNow()
    } catch { syncStatus = error.localizedDescription }
  }
  func continueArchive() {
    guard let old = selected, old.engine == .chatgptArchive else { return }
    guard let profile = profiles.first(where: { $0.id == settings.selectedProfileID }) ?? profiles.first else { banner = "请先在设置中添加 API 连接。"; return }
    guard activate(.api(profile)) else { return }
    var c = Conversation(cwd: scratch.path)
    c.backend = .api; c.profileID = profile.id; c.modelID = profile.defaultModel
    c.title = old.title; c.items = old.items
    state.conversations.append(c); select(c.id)
    banner = "已创建 \(profile.name) 的续聊副本。发送下一条消息时，会将此副本中的对话上下文提交给该服务。"
    saveNow()
  }
}
