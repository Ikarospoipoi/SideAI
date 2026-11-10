import AppKit
import Combine
import CryptoKit
import SideAICore
import SideAIRemote

struct RemoteHostConfiguration: Codable {
  var pairing: RemotePairing
  var deviceID: String?
  var deviceName: String?
  var paused: Bool?
}

@MainActor final class RemoteHost: ObservableObject {
  @Published var status = "未开启"
  @Published var configuration: RemoteHostConfiguration?
  @Published var pendingDevice: (id: String, name: String)?
  @Published var enabled = false
  private weak var store: SessionStore?
  private let channel = RemoteChannel()
  private var timer: Task<Void, Never>?
  private var challenge = UUID().uuidString
  private var phoneNonce = ""
  private var currentDevice = ""
  private var watchedID: UUID?
  private var handled = Set<String>()
  private var lastSnapshot = ""
  private var lastPublished = Date.distantPast
  init(store: SessionStore, loadSaved: Bool = true) {
    self.store = store
    channel.onStatus = { [weak self] status, connected in
      self?.status = status
      if !connected { self?.phoneNonce = ""; self?.currentDevice = ""; self?.challenge = UUID().uuidString }
    }
    channel.onReady = { [weak self] in self?.challenge = UUID().uuidString; self?.lastSnapshot = "" }
    channel.onMessage = { [weak self] message in self?.receive(message) }
    do {
      if loadSaved, let data = try RemoteVault.read("host") { configuration = try JSONDecoder().decode(RemoteHostConfiguration.self, from: data) }
    } catch { status = error.localizedDescription }
  }
  func resume() { if configuration?.deviceID != nil, configuration?.paused != true { start() } }
  func create(relay: String) {
    do {
      let next = RemoteHostConfiguration(pairing: try RemotePairing(relay: relay, name: Host.current().localizedName ?? "我的电脑"))
      try RemoteVault.save(JSONEncoder().encode(next), account: "host")
      configuration = next; pendingDevice = nil; start()
    } catch { status = error.localizedDescription }
  }
  func start(persistConfiguration: Bool = true) {
    guard var config = configuration else { return }
    config.paused = false
    do { if persistConfiguration { try RemoteVault.save(JSONEncoder().encode(config), account: "host") }; configuration = config } catch { status = error.localizedDescription; return }
    stop(); enabled = true; handled.removeAll(); phoneNonce = ""; currentDevice = ""; challenge = UUID().uuidString
    channel.start(config.pairing, role: "host")
    timer = Task { [weak self] in
      while !Task.isCancelled { try? await Task.sleep(nanoseconds: 700_000_000); guard !Task.isCancelled else { return }; self?.publish() }
    }
  }
  func pause() {
    guard var config = configuration else { return }
    config.paused = true
    do { try RemoteVault.save(JSONEncoder().encode(config), account: "host"); configuration = config; stop() } catch { status = error.localizedDescription }
  }
  func stop() { timer?.cancel(); timer = nil; channel.stop(); enabled = false; currentDevice = ""; phoneNonce = ""; status = "远程已暂停" }
  func revoke() {
    stop()
    do { try RemoteVault.delete("host"); configuration = nil; pendingDevice = nil; status = "已解除手机配对" }
    catch { status = error.localizedDescription }
  }
  func approveDevice() {
    guard let pendingDevice, var next = configuration, next.pairing.expires > Date().timeIntervalSince1970 else { status = "配对已过期，请重新生成"; return }
    do {
      next.deviceID = pendingDevice.id; next.deviceName = pendingDevice.name
      try RemoteVault.save(JSONEncoder().encode(next), account: "host"); configuration = next; self.pendingDevice = nil
      challenge = UUID().uuidString; status = "手机已连接 · 可遥控"; publish(force: true)
    } catch { status = error.localizedDescription }
  }
  func receive(_ message: RemoteValue) {
    guard enabled, let config = configuration, abs(message["time"].number - Date().timeIntervalSince1970) < 60 else { return }
    if message["kind"].text == "hello" {
      let id = message["device"].text, nonce = message["nonce"].text
      guard UUID(uuidString: id) != nil, UUID(uuidString: nonce) != nil else { return }
      guard config.deviceID == id || (config.deviceID == nil && config.pairing.expires > Date().timeIntervalSince1970) else { return }
      currentDevice = id; phoneNonce = nonce; challenge = UUID().uuidString
      if watchedID == nil { watchedID = store?.selectedID }
      if config.deviceID == nil { pendingDevice = (id, String(message["name"].text.prefix(60))); status = "请确认手机配对" }
      else { status = "手机已连接 · 可遥控" }
      publish(force: true); return
    }
    guard config.deviceID == currentDevice, !currentDevice.isEmpty, message["nonce"].text == phoneNonce,
      message["challenge"].text == challenge, message["kind"].text == "command" else { return }
    let id = message["id"].text
    guard UUID(uuidString: id) != nil else { return }
    guard !handled.contains(id) else { reply(id, error: "此指令已经处理，请刷新查看结果。"); return }
    guard handled.count < 5000 else { reply(id, error: "请重新连接手机后继续"); return }
    handled.insert(id)
    do { try execute(message); reply(id, error: nil) }
    catch { reply(id, error: error.localizedDescription) }
    publish(force: true)
  }
  private func reply(_ id: String, error: String?) {
    channel.send(.object(["kind": .string("ack"), "nonce": .string(phoneNonce), "id": .string(id), "error": error.map(RemoteValue.string) ?? .null, "selected": watchedID.map { .string($0.uuidString) } ?? .null]))
  }
  private func execute(_ message: RemoteValue) throws {
    guard let store else { throw RemoteError.message("电脑已离线") }
    let operation = message["op"].text
    if operation == "watch" {
      guard let id = UUID(uuidString: message["conversation"].text), store.state.conversations.contains(where: { $0.id == id }) else { throw RemoteError.message("会话不存在") }
      watchedID = id; return
    }
    if operation == "new" {
      guard !store.isBusy, let route = store.routes.first(where: { $0.id == message["route"].text }) else { throw RemoteError.message("请等待当前任务结束，或检查连接") }
      store.newConversation(route: route); watchedID = store.selectedID
      if route.backend == .codex { store.connect() }; if route.backend == .claude { store.refreshClaudeStatus() }
      return
    }
    if operation == "approve" {
      let id = message["approval"].text, allow = message["allow"].bool
      guard let row = approvals().first(where: { $0["id"].text == id }), row["fingerprint"].text == message["fingerprint"].text,
        !allow || row["canApprove"].bool else { throw RemoteError.message("审批已改变、已处理或需在电脑上查看，请刷新") }
      if let request = store.pending.first(where: { $0.id == id }), !request.submitted {
        guard store.ready, request.generation == store.state.generation else { throw RemoteError.message("Agent 已断开，请在电脑重新连接后处理") }
        var answers = [String: String]()
        for q in request.params["questions"].array {
          let value = message["answers"][q["id"].text].text
          guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count < 5000 else { throw RemoteError.message("请完整回答问题") }
          answers[q["id"].text] = value
        }
        store.respond(request, allow: allow, answers: answers); return
      }
      if let request = store.claudeApprovals.first(where: { "claude:" + $0.conversationID.uuidString + ":" + $0.id == id }), let client = store.claudeClients[request.conversationID] {
        client.sendControl(ClaudePermissions.reply(id: request.id, input: request.input, allow: allow))
        store.claudeApprovals.removeAll { $0.id == request.id && $0.conversationID == request.conversationID }; store.mutate(request.conversationID) { $0.status = .running }; return
      }
      throw RemoteError.message("审批已失效")
    }
    guard let id = UUID(uuidString: message["conversation"].text), let c = store.state.conversations.first(where: { $0.id == id }) else { throw RemoteError.message("会话不存在") }
    watchedID = id
    if operation == "stop" { store.interrupt(id); return }
    guard !store.isBusy, revision(c) == message["revision"].text else { throw RemoteError.message("电脑上的会话已改变或正在运行，请刷新后再试") }
    let route = store.route(for: c)
    guard store.routes.contains(where: { $0.id == route.id }), store.activate(route) else { throw RemoteError.message("此连接不可用") }
    store.select(id)
    if operation == "models" {
      if c.engine == .codex && !store.ready { store.connect() }
      else if c.engine == .claude && !store.claudeReady { store.refreshClaudeStatus() }
      store.refreshCurrentModels(); return
    }
    if operation == "configure" {
      let model = message["model"].text, effort = message["effort"].text, mode = message["mode"].text, cwd = message["cwd"].text
      guard !model.isEmpty, model.count <= 200, effort.count <= 40, ["readOnly", "project"].contains(mode), (cwd == c.cwd || projects().contains(where: { $0["path"].text == cwd })) else { throw RemoteError.message("模型或项目无效，请在电脑上先添加项目") }
      let option = store.availableModels.first { $0.id == model }
      guard effort.isEmpty || (option?.efforts ?? ["none", "minimal", "low", "medium", "high", "xhigh", "max"]).contains(effort) else { throw RemoteError.message("推理强度无效") }
      store.mutate(id) { $0.modelID = model; $0.reasoningEffort = effort.isEmpty ? nil : effort; $0.cwd = cwd; if c.workspace == .agent { $0.mode = mode == "project" ? .project : .readOnly } }
      return
    }
    if operation == "send" {
      // select() restores Codex history asynchronously. Never race that restore with a new turn.
      guard c.engine != .codex || c.threadID == nil || store.restored.contains(id) else {
        throw RemoteError.message(store.ready ? "正在同步这条任务的历史，请稍后再发送。" : "请先刷新模型／电脑连接，再继续这条任务。")
      }
      let text = message["text"].text
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 50000 else { throw RemoteError.message("消息为空或过长") }
      guard c.draft.isEmpty, c.images.isEmpty else { throw RemoteError.message("电脑有未发送草稿，请先处理或在手机新建会话") }
      guard store.currentConnectionReady else { throw RemoteError.message("电脑连接尚未就绪，请点击刷新模型／连接后重试") }
      store.mutate(id) { $0.draft = text }; store.send()
      guard store.state.conversations.first(where: { $0.id == id })?.status.isActive == true else {
        if let latest = store.state.conversations.first(where: { $0.id == id }), latest.items.count == c.items.count, latest.draft == text { store.mutate(id) { $0.draft = "" } }
        throw RemoteError.message(store.banner ?? "未开始发送，请检查电脑")
      }
      return
    }
    throw RemoteError.message("不支持的远程操作")
  }
  private func fingerprint(_ text: String) -> String { Data(SHA256.hash(data: Data(text.utf8))).map { String(format: "%02x", $0) }.joined() }
  func revision(_ c: Conversation) -> String { fingerprint([c.id.uuidString,c.status.rawValue,c.modelID ?? "",c.reasoningEffort ?? "",c.cwd,c.mode.rawValue,String(c.updatedAt.timeIntervalSince1970),String(c.items.count),c.items.last?.id ?? "",String(c.items.last?.text.count ?? 0),c.draft,String(c.images.count)].joined(separator: "|")) }
  private func projects() -> [RemoteValue] {
    guard let store else { return [] }
    return Set([store.scratch.path] + store.state.conversations.filter { $0.workspace == .agent }.map(\.cwd)).sorted().map { .object(["path": .string($0), "name": .string($0 == store.scratch.path ? "临时工作区" : URL(fileURLWithPath: $0).lastPathComponent)]) }
  }
  private func approvals() -> [RemoteValue] {
    guard let store else { return [] }
    func row(id: String, conversation: String, title: String, detail: String, cwd: String, questions: RemoteValue = .array([])) -> RemoteValue {
      .object(["id": .string(id), "conversation": .string(conversation), "title": .string(title), "detail": .string(String(detail.prefix(60000))), "cwd": .string(cwd), "canApprove": .bool(detail.count <= 60000), "fingerprint": .string(fingerprint(id + detail + cwd)), "questions": questions])
    }
    return store.pending.filter { !$0.submitted }.compactMap { r in
      guard let c = store.state.conversations.first(where: { $0.threadID == r.threadID }) else { return nil }
      let questions = (try? JSONDecoder().decode(RemoteValue.self, from: JSONEncoder().encode(r.params["questions"]))) ?? .array([])
      return row(id: r.id, conversation: c.id.uuidString, title: r.isQuestion ? "Agent 需要你的回答" : "Codex 请求操作权限", detail: r.params.pretty, cwd: c.cwd, questions: questions)
    } + store.claudeApprovals.map { r in row(id: "claude:" + r.conversationID.uuidString + ":" + r.id, conversation: r.conversationID.uuidString, title: "Claude Code · " + r.tool, detail: r.input.pretty, cwd: r.cwd) }
  }
  func snapshot() -> RemoteValue {
    guard let store else { return .null }
    let routes: [RemoteValue] = store.routes.map { route in
      let models: [ModelOption]
      switch route.backend {
      case .codex: models = store.codexModels
      case .claude: models = ClaudeProtocol.models
      case .api: models = route.profileID.flatMap { store.apiModels[$0] } ?? []
      case .accountRuntime: models = AccountRuntime.allCases.first(where: { $0.route.id == route.id }).flatMap { store.accountModels[$0] } ?? []
      default: models = []
      }
      return .object(["id": .string(route.id), "name": .string(route.name), "workspace": .string(route.workspace.rawValue), "models": .array(models.prefix(200).map { .object(["id": .string($0.id), "name": .string($0.name), "efforts": .array($0.efforts.map(RemoteValue.string))]) })])
    }
    let conversations = store.state.conversations.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(300)
    let current = store.state.conversations.first { $0.id == (watchedID ?? store.selectedID) }
    var detail: RemoteValue = .null
    if let c = current {
      detail = .object(["id": .string(c.id.uuidString), "route": .string(c.routeID), "title": .string(c.title), "status": .string(c.status.label), "active": .bool(c.status.isActive), "model": .string(c.modelID ?? ""), "effort": .string(c.reasoningEffort ?? ""), "mode": .string(c.mode.rawValue), "cwd": .string(c.cwd), "revision": .string(revision(c)), "error": .string(c.error ?? ""), "items": .array(c.items.suffix(60).map { .object(["id": .string($0.id), "role": .string($0.kind), "text": .string(String(($0.text.isEmpty ? $0.detail : $0.text).prefix(8000))), "truncated": .bool(($0.text.isEmpty ? $0.detail : $0.text).count > 8000), "status": .string($0.status)]) })])
    }
    return .object(["kind": .string("state"), "nonce": .string(phoneNonce), "challenge": .string(challenge), "host": .string(configuration?.pairing.name ?? "电脑"), "routes": .array(routes), "busy": .bool(store.isBusy), "projects": .array(projects()), "conversations": .array(conversations.map { .object(["id": .string($0.id.uuidString), "route": .string($0.routeID), "title": .string($0.title), "status": .string($0.status.label)]) }), "current": detail, "approvals": .array(Array(approvals().prefix(4)))])
  }
  private func publish(force: Bool = false) {
    guard channel.connected, !phoneNonce.isEmpty else { return }
    guard configuration?.deviceID == currentDevice else {
      if force { channel.send(.object(["kind": .string("pairing"), "nonce": .string(phoneNonce)])) }; return
    }
    var value = snapshot()
    // Bound the encrypted snapshot; retain newest messages and actionable approvals.
    if case .object(var object) = value, case .object(var current) = object["current"] {
      var items = current["items"]?.array ?? []
      while value.pretty.utf8.count > 1_250_000 && !items.isEmpty {
        items.removeFirst(); current["items"] = .array(items); current["historyLimited"] = .bool(true)
        object["current"] = .object(current); value = .object(object)
      }
    }
    let digest = fingerprint(value.pretty)
    if force || digest != lastSnapshot || Date().timeIntervalSince(lastPublished) > 10 { lastSnapshot = digest; lastPublished = Date(); channel.send(value) }
  }
}
