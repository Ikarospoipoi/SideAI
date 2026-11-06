import Foundation

public enum PanelState: String {
  case collapsed, peek, expanded, pinned
  public var isOpen: Bool { self == .expanded || self == .pinned }
  public mutating func toggle() { self = isOpen ? .collapsed : .expanded }
  public mutating func outsideClick() {
    if self == .expanded || self == .peek { self = .collapsed }
  }
}
public enum SessionStatus: String, Codable {
  case idle, running, awaitingApproval, awaitingInput, completed, interrupted, failed
  public var isActive: Bool { [.running, .awaitingApproval, .awaitingInput].contains(self) }
  public var label: String {
    switch self {
    case .idle: return "就绪"
    case .running: return "进行中"
    case .awaitingApproval: return "等待确认"
    case .awaitingInput: return "等待回答"
    case .completed: return "已完成"
    case .interrupted: return "已停止"
    case .failed: return "需要检查"
    }
  }
}
public enum AgentMode: String, Codable, CaseIterable {
  case readOnly, project
  public var label: String { self == .readOnly ? "只读 Agent" : "项目 Agent" }
  public var sandbox: String { self == .readOnly ? "read-only" : "workspace-write" }
  public func policy(cwd: String) -> JSON {
    self == .readOnly
      ? .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
      : .object([
        "type": .string("workspaceWrite"), "writableRoots": .array([.string(cwd)]),
        "networkAccess": .bool(false), "excludeSlashTmp": .bool(true),
        "excludeTmpdirEnvVar": .bool(true),
      ])
  }
}
public struct TimelineItem: Codable, Identifiable, Equatable {
  public var id: String
  public var kind: String
  public var text: String
  public var detail: String
  public var status: String
  public var attachments: [ImageAttachment]?
  public init(
    id: String = UUID().uuidString, kind: String, text: String, detail: String = "",
    status: String = "completed"
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.detail = detail
    self.status = status
  }
}
public struct Conversation: Codable, Identifiable {
  public var id = UUID()
  public var title = "新会话"
  public var threadID: String?
  public var turnID: String?
  public var cwd: String
  public var mode: AgentMode = .readOnly
  public var draft = ""
  public var archived = false
  public var items = [TimelineItem]()
  public var status: SessionStatus = .idle
  public var error: String?
  public var updatedAt = Date()
  // Optional additions keep v0.1 snapshots readable without dropping existing drafts.
  public var backend: BackendKind?
  public var profileID: UUID?
  public var modelID: String?
  public var reasoningEffort: String?
  public var attachments: [ImageAttachment]?
  public var importID: String?
  public var originCategory: String?
  public var imported: Bool?
  public var locallyRenamed: Bool?
  public var claudeSessionID: String?
  public var claudeHasSession: Bool?
  public var resolvedModel: String?
  public var handoff: HandoffLink?
  public var claudeAgentEnabled: Bool?
  public var accountRuntime: AccountRuntime?
  public var claudeChatOnly: Bool?
  public init(cwd: String) { self.cwd = cwd }
  public mutating func upsert(_ item: TimelineItem) {
    if let i = items.firstIndex(where: { $0.id == item.id }) {
      var merged = item
      if merged.attachments == nil || merged.attachments?.map(\.path) == items[i].attachments?.map(\.path) { merged.attachments = items[i].attachments }
      items[i] = merged
    } else {
      items.append(item)
    }
  }
}
public struct PendingRequest: Identifiable, Equatable {
  public var id: String { "\(generation.uuidString):\(requestID.key)" }
  public let requestID: JSON
  public let method: String
  public let params: JSON
  public let generation: UUID
  public let receivedAt: Date
  public var submitted = false
  public var threadID: String { params["threadId"].text }
  public var itemID: String { params["itemId"].text }
  public var isQuestion: Bool { method == "item/tool/requestUserInput" }
  public init(
    requestID: JSON, method: String, params: JSON, generation: UUID, receivedAt: Date = Date()
  ) {
    self.requestID = requestID
    self.method = method
    self.params = params
    self.generation = generation
    self.receivedAt = receivedAt
  }
}

public struct EventState {
  public var conversations: [Conversation]
  public var pending = [PendingRequest]()
  public var generation = UUID()
  private var resolvedRequests = Set<String>()
  public init(conversations: [Conversation] = []) { self.conversations = conversations }
  public mutating func invalidateConnection() {
    generation = UUID()
    pending.removeAll()
    resolvedRequests.removeAll()
    for i in conversations.indices where conversations[i].status.isActive && conversations[i].engine == .codex {
      conversations[i].status = .failed
      conversations[i].error = "连接中断；请重新连接并恢复会话。不会自动重发请求。"
    }
  }
  /// Returns true when a new server request was queued. Unknown notifications are harmless.
  @discardableResult public mutating func receive(_ message: JSON) -> Bool {
    let method = message["method"].text
    let p = message["params"]
    guard
      let i = conversations.firstIndex(where: {
        $0.threadID == p["threadId"].string && $0.threadID != nil
      })
    else { return false }
    if message["id"] != .null {
      let request = PendingRequest(
        requestID: message["id"], method: method, params: p, generation: generation)
      guard !resolvedRequests.contains(request.id),
        !pending.contains(where: { $0.id == request.id })
      else { return false }
      pending.append(request)
      conversations[i].status = request.isQuestion ? .awaitingInput : .awaitingApproval
      return true
    }
    switch method {
    case "turn/started":
      conversations[i].turnID = p["turn"]["id"].string
      conversations[i].status = .running
      conversations[i].error = nil
    case "turn/completed":
      guard conversations[i].turnID == nil || conversations[i].turnID == p["turn"]["id"].text else {
        break
      }
      switch p["turn"]["status"].text {
      case "completed": conversations[i].status = .completed
      case "interrupted": conversations[i].status = .interrupted
      default: conversations[i].status = .failed
      }
      conversations[i].error = p["turn"]["error"]["message"].string
      conversations[i].turnID = nil
      clearPending { $0.threadID == p["threadId"].text }
    case "item/started", "item/completed":
      let raw = p["item"]
      var item = Self.timelineItem(raw)
      if method == "item/started" && raw["status"] == .null { item.status = "inProgress" }
      if raw["type"].text == "userMessage",
        let local = conversations[i].items.lastIndex(where: {
          $0.id.hasPrefix("local:") && $0.text == item.text
        })
      {
        item.attachments = conversations[i].items[local].attachments
        conversations[i].items.remove(at: local)
      }
      if method == "item/completed" || !conversations[i].items.contains(where: { $0.id == item.id })
      {
        conversations[i].upsert(item)
      }
      if method == "item/completed" {
        clearPending { $0.threadID == p["threadId"].text && $0.itemID == item.id }
      }
    case "item/agentMessage/delta", "item/commandExecution/outputDelta":
      let id = p["itemId"].text
      let isMessage = method == "item/agentMessage/delta"
      if !conversations[i].items.contains(where: { $0.id == id }) {
        conversations[i].items.append(
          TimelineItem(
            id: id, kind: isMessage ? "agentMessage" : "commandExecution", text: "",
            status: "inProgress"))
      }
      if let j = conversations[i].items.firstIndex(where: { $0.id == id }),
        conversations[i].items[j].status == "inProgress"
      {
        if isMessage {
          conversations[i].items[j].text += p["delta"].text
        } else {
          conversations[i].items[j].detail = String(
            (conversations[i].items[j].detail + p["delta"].text).suffix(100_000))
        }
      }
    case "serverRequest/resolved":
      resolvedRequests.insert("\(generation.uuidString):\(p["requestId"].key)")
      clearPending { $0.threadID == p["threadId"].text && $0.requestID == p["requestId"] }
    case "error":
      conversations[i].error = p["error"]["message"].string ?? "后端报告错误"
      if !p["willRetry"].bool {
        conversations[i].status = .failed
        conversations[i].turnID = nil
        clearPending { $0.threadID == p["threadId"].text }
      }
    case "turn/plan/updated":
      let detail = p["plan"].array.map { "\($0["status"].text) · \($0["step"].text)" }.joined(
        separator: "\n")
      conversations[i].upsert(
        TimelineItem(
          id: "plan:" + p["turnId"].text, kind: "plan", text: p["explanation"].string ?? "任务计划",
          detail: detail))
    default: break
    }
    if conversations[i].status == .awaitingApproval || conversations[i].status == .awaitingInput {
      if !pending.contains(where: { $0.threadID == conversations[i].threadID }) {
        conversations[i].status = .running
      }
    }
    return false
  }
  private mutating func clearPending(where predicate: (PendingRequest) -> Bool) {
    for request in pending where predicate(request) { resolvedRequests.insert(request.id) }
    pending.removeAll(where: predicate)
  }
  public static func timelineItem(_ raw: JSON) -> TimelineItem {
    let type = raw["type"].text
    var text = raw["text"].text
    var detail = ""
    switch type {
    case "userMessage":
      text = raw["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
    case "commandExecution":
      text = raw["command"].text
      detail = raw["aggregatedOutput"].text
    case "fileChange":
      text = "文件修改"
      detail = raw["changes"].pretty
    case "mcpToolCall", "dynamicToolCall":
      text = raw["tool"].string ?? "工具调用"
      detail = raw.pretty
    case "reasoning":
      text = "思考"
      detail = raw["summary"].array.map { $0.string ?? $0["text"].text }.joined(separator: "\n")
    case "webSearch": text = "搜索 · " + raw["query"].text
    case "agentMessage": break
    default:
      text = type
      detail = raw.pretty
    }
    var result = TimelineItem(
      id: raw["id"].text, kind: type, text: text, detail: String(detail.suffix(100_000)),
      status: raw["status"].string ?? "completed")
    if type == "userMessage" {
      result.attachments = raw["content"].array.compactMap { content in
        guard content["type"].text == "localImage", let path = content["path"].string else { return nil }
        return ImageAttachment(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
      }
      if result.attachments?.isEmpty == true { result.attachments = nil }
    }
    return result
  }
}
