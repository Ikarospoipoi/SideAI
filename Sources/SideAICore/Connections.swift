import Foundation

public enum BackendKind: String, Codable, CaseIterable {
  case codex, claude, api, accountRuntime, chatgptArchive
  public var label: String { switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .api: return "API"; case .accountRuntime: return "官方账号"; case .chatgptArchive: return "ChatGPT 导入" } }
}
public enum APIFormat: String, Codable, CaseIterable {
  case responses, chatCompletions, anthropic
  public var label: String { switch self { case .responses: return "Responses API"; case .chatCompletions: return "Chat Completions 兼容 API"; case .anthropic: return "Anthropic Messages API" } }
}
public enum ChatAuthentication: String, Codable { case apiKey, chatgptPlan, openRouterOAuth }
public struct APIProfile: Codable, Identifiable, Equatable {
  public var id = UUID()
  public var name = "OpenAI"
  public var baseURL = "https://api.openai.com/v1"
  public var format: APIFormat = .responses
  public var defaultModel = ""
  public var provider: ProviderKind?
  public var authentication: ChatAuthentication?
  public var accountLabel: String?
  public var oauthClientID: String?
  public var oauthSubject: String?
  public var auth: ChatAuthentication { authentication ?? .apiKey }
  public init() {}
  public func endpoint(_ path: String) throws -> URL {
    guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    else { throw ProtocolError.message("API 地址需为 HTTPS；仅本机 localhost 可使用 HTTP。不能包含用户名、密码、查询或 fragment。") }
    return url.appendingPathComponent(path)
  }
}
public struct ModelOption: Identifiable, Equatable {
  public var id: String
  public var name: String
  public var efforts: [String]
  public var defaultEffort: String?
  public var supportsImages: Bool?
  public init(id: String, name: String? = nil, efforts: [String] = [], defaultEffort: String? = nil, supportsImages: Bool? = nil) {
    self.id = id; self.name = name ?? id; self.efforts = efforts; self.defaultEffort = defaultEffort; self.supportsImages = supportsImages
  }
  public init(codex: JSON) {
    self.init(id: codex["model"].text, name: codex["displayName"].string,
      efforts: codex["supportedReasoningEfforts"].array.map { $0["reasoningEffort"].text },
      defaultEffort: codex["defaultReasoningEffort"].string,
      supportsImages: codex["inputModalities"] == .null ? nil : codex["inputModalities"].array.contains(.string("image")))
  }
}
public struct ImageAttachment: Codable, Identifiable, Equatable {
  public var id: UUID
  public var path: String
  public var name: String
  public var mimeType: String
  public init(id: UUID = UUID(), path: String, name: String, mimeType: String = "image/png") {
    self.id = id; self.path = path; self.name = name; self.mimeType = mimeType
  }
  public func dataURL() throws -> String { "data:\(mimeType);base64," + (try Data(contentsOf: URL(fileURLWithPath: path))).base64EncodedString() }
}
extension Conversation {
  public var engine: BackendKind { backend ?? .codex }
  public var images: [ImageAttachment] { attachments ?? [] }
  public var isGPT: Bool { engine == .api || engine == .chatgptArchive || originCategory == "chatgpt" }
  public var canSendContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }
  public func codexTurnParams(threadID: String, memory: MemoryContext? = nil) -> JSON {
    var input: [JSON] = []
    let text = memory?.augment(draft) ?? draft
    if !text.isEmpty { input.append(.object(["type": .string("text"), "text": .string(text)])) }
    input += images.map { .object(["type": .string("localImage"), "path": .string($0.path)]) }
    var params: [String: JSON] = ["threadId": .string(threadID), "input": .array(input),
      "cwd": .string(cwd), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"), "sandboxPolicy": mode.policy(cwd: cwd)]
    if let modelID, !modelID.isEmpty { params["model"] = .string(modelID) }
    if let reasoningEffort, !reasoningEffort.isEmpty { params["effort"] = .string(reasoningEffort) }
    return .object(params)
  }
}

public enum APIRequestBuilder {
  /// Full local context, no tool declarations and no automatic cross-provider response IDs.
  public static func body(conversation: Conversation, format: APIFormat, model: String, memory: MemoryContext? = nil) throws -> JSON {
    guard !model.isEmpty else { throw ProtocolError.message("请先选择或输入模型 ID") }
    let history = conversation.items.filter { ["userMessage", "agentMessage"].contains($0.kind) && $0.status == "completed" }
    var rows: [JSON] = []
    for item in history {
      let role = item.kind == "userMessage" ? "user" : "assistant"
      var parts: [JSON] = []
      let text = item.id == history.last(where: { $0.kind == "userMessage" })?.id ? memory?.augment(item.text) ?? item.text : item.text
      if !text.isEmpty {
        parts.append(.object(["type": .string(format != .responses ? "text" : role == "user" ? "input_text" : "output_text"), "text": .string(text)]))
      }
      for attachment in item.attachments ?? [] where role == "user" {
        let url = try attachment.dataURL()
        if format == .anthropic {
          parts.append(.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string(attachment.mimeType), "data": .string(String(url.split(separator: ",", maxSplits: 1)[1]))])]))
          continue
        }
        parts.append(format == .responses ? .object(["type": .string("input_image"), "image_url": .string(url)]) : .object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])]))
      }
      if !parts.isEmpty { rows.append(.object(["role": .string(role), "content": .array(parts)])) }
    }
    var body: [String: JSON] = ["model": .string(model), "stream": .bool(true)]
    if format == .responses {
      body["input"] = .array(rows); body["store"] = .bool(false)
      if let effort = conversation.reasoningEffort, !effort.isEmpty { body["reasoning"] = .object(["effort": .string(effort)]) }
    } else {
      body["messages"] = .array(rows)
      if format == .anthropic {
        body["max_tokens"] = .number(4096)
        if let effort = conversation.reasoningEffort, !effort.isEmpty { body["output_config"] = .object(["effort": .string(effort)]) }
      }
    }
    return .object(body)
  }
}

/// SSE messages may contain multiple data lines, comments and CRLF endings.
public struct SSEDecoder {
  private var lines = [String]()
  private var pendingBytes = [UInt8]()
  public init() {}
  public mutating func consume(byte: UInt8) throws -> String? {
    if byte == 10 {
      guard let line = String(bytes: pendingBytes, encoding: .utf8) else { throw ProtocolError.message("API 返回了无效 UTF-8") }
      pendingBytes.removeAll(keepingCapacity: true)
      return try consume(line)
    }
    pendingBytes.append(byte)
    guard pendingBytes.count <= 4_000_000 else { throw ProtocolError.message("API 流事件超过大小限制") }
    return nil
  }
  public mutating func consume(_ line: String) throws -> String? {
    let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
    if line.isEmpty { guard !lines.isEmpty else { return nil }; defer { lines.removeAll(keepingCapacity: true) }; return lines.joined(separator: "\n") }
    if line.hasPrefix("data:") {
      var data = String(line.dropFirst(5)); if data.first == " " { data.removeFirst() }; lines.append(data)
      if lines.reduce(0, { $0 + $1.utf8.count }) > 4_000_000 { throw ProtocolError.message("API 流事件超过大小限制") }
    }
    return nil
  }
}
