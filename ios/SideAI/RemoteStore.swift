import Foundation
import SwiftUI
import SideAIRemote

struct PhoneConfiguration: Codable {
  var pairing: RemotePairing
  var deviceID = UUID().uuidString
}
@MainActor final class RemoteStore: ObservableObject {
  @Published var configuration: PhoneConfiguration?
  @Published var state: RemoteValue = .null
  @Published var status = "连接你的电脑"
  @Published var online = false
  @Published var error: String?
  @Published var pending = false
  @Published var draft = ""
  @Published var lastSentText: String?
  private let channel = RemoteChannel()
  private var nonce = UUID().uuidString
  private var commandID: String?
  private var commandOp = ""
  private var timeout: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var lastSeen = Date.distantPast
  private var simulatorDemo = false
  private var drafts: [String: String] = [:]
  private var draftConversation = ""
  var current: RemoteValue { state["current"] }
  var hasComputer: Bool { configuration != nil }
  var routes: [RemoteValue] { state["routes"].array }
  var approvals: [RemoteValue] { state["approvals"].array }
  init() {
    channel.onStatus = { [weak self] value, connected in
      self?.status = value
      if !connected { self?.online = false; self?.state = .null; self?.uncertain() }
    }
    channel.onReady = { [weak self] in self?.hello() }
    channel.onPeer = { [weak self] in self?.hello() }
    channel.onMessage = { [weak self] in self?.receive($0) }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--ui-demo") { installDemo(); return }
    #endif
    do { if let data = try RemoteVault.read("phone") { configuration = try JSONDecoder().decode(PhoneConfiguration.self, from: data) } }
    catch { self.error = "无法读取配对，请重新配对。" }
  }
  func pair(_ link: String) {
    do {
      let next = PhoneConfiguration(pairing: try RemotePairing.parse(link))
      try RemoteVault.save(JSONEncoder().encode(next), account: "phone"); configuration = next; drafts.removeAll(); draft = ""; draftConversation = ""; error = nil; connect()
    } catch { self.error = error.localizedDescription }
  }
  func connect() {
    guard !simulatorDemo, let config = configuration else { return }
    online = false; state = .null; lastSeen = .distantPast
    channel.start(config.pairing, role: "phone")
    heartbeat?.cancel(); heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled, let self else { return }
        if self.online && Date().timeIntervalSince(self.lastSeen) > 25 { self.online = false; self.status = "电脑未响应，正在重新同步…"; self.hello() }
      }
    }
  }
  func suspend() { if simulatorDemo { return }; channel.stop(); heartbeat?.cancel(); online = false; state = .null; uncertain(); status = "回到前台后重新连接" }
  func unpair() {
    suspend()
    do { try RemoteVault.delete("phone"); configuration = nil; status = "连接你的电脑"; draft = ""; drafts.removeAll(); draftConversation = "" }
    catch { self.error = error.localizedDescription }
  }
  private func hello() {
    guard let config = configuration else { return }
    uncertain(); nonce = UUID().uuidString; online = false
    channel.send(.object(["kind": .string("hello"), "device": .string(config.deviceID), "nonce": .string(nonce), "name": .string(UIDevice.current.name), "time": .number(Date().timeIntervalSince1970)]))
  }
  private func receive(_ message: RemoteValue) {
    guard message["nonce"].text == nonce else { return }
    if message["kind"].text == "pairing" { status = "请在电脑上允许这台手机"; online = false; return }
    if message["kind"].text == "state" {
      let id = message["current"]["id"].text
      if draftConversation != id { drafts[draftConversation] = draft; draft = drafts[id] ?? ""; draftConversation = id }
      state = message; lastSeen = Date(); online = true; status = "已连接 · " + message["host"].text; return }
    if message["kind"].text == "ack", message["id"].text == commandID {
      timeout?.cancel(); pending = false; commandID = nil
      if let problem = message["error"].string { error = problem }
      else if commandOp == "send" { if draft == lastSentText { draft = "" }; lastSentText = nil }
    }
  }
  func command(_ op: String, fields: [String: RemoteValue] = [:]) {
    guard online, !pending else { return }
    if simulatorDemo { error = "这是离线界面演示，不会执行指令。"; return }
    var request = fields
    request["kind"] = .string("command"); request["op"] = .string(op); request["id"] = .string(UUID().uuidString)
    request["nonce"] = .string(nonce); request["challenge"] = state["challenge"]
    request["time"] = .number(Date().timeIntervalSince1970)
    if request["conversation"] == nil { request["conversation"] = current["id"] }
    if request["revision"] == nil { request["revision"] = current["revision"] }
    commandID = request["id"]?.text; commandOp = op; pending = true; error = nil
    if op == "send" { lastSentText = fields["text"]?.text }
    channel.send(.object(request))
    timeout?.cancel(); timeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard !Task.isCancelled else { return }; self?.uncertain()
    }
  }
  private func uncertain() {
    if pending { error = "连接发生变化，指令状态未确认。请查看电脑同步的消息或任务后再决定是否重试；不会自动重发。" }
    timeout?.cancel(); pending = false; commandID = nil
  }
  #if DEBUG
  private func installDemo() {
    simulatorDemo = true; online = true; status = "界面演示 · 不连接真实电脑"
    let json = #"""
    {"host":"我的 Mac","routes":[{"id":"codex","name":"Codex","workspace":"agent","models":[{"id":"model-a","name":"当前模型","efforts":["medium","high"]}]}],"current":{"id":"demo","title":"继续昨天的 SQL 任务","route":"codex","status":"等待确认","model":"model-a","effort":"high","cwd":"/Projects/Stock","mode":"project","active":true,"items":[{"id":"1","role":"userMessage","text":"帮我检查查询逻辑，并修复关联条件。"},{"id":"2","role":"agentMessage","text":"已找到关联字段不一致的问题。修改准备好了，等待你确认后写入。"}]},"conversations":[],"approvals":[{"id":"demo-approval","title":"Codex 请求修改文件","cwd":"/Projects/Stock","detail":"更新 queries/orders.sql\n将关联字段改为 b.TRACE_ID","canApprove":true,"questions":[]}],"busy":true,"projects":[]}
    """#
    state = (try? JSONDecoder().decode(RemoteValue.self, from: Data(json.utf8))) ?? .null
  }
  #endif
}
