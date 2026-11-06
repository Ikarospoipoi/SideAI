import Foundation

public enum ClaudeProtocol {
  public static let models: [ModelOption] = ["sonnet", "opus", "haiku", "fable"].map {
    ModelOption(id: $0, name: "Claude " + $0.capitalized, efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", supportsImages: true)
  }
  public static func arguments(conversation: Conversation) throws -> [String] {
    guard let session = conversation.claudeSessionID, UUID(uuidString: session) != nil else { throw ProtocolError.message("Claude 会话 ID 无效") }
    var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ClaudePermissions.tools(for: conversation).joined(separator: ","), "--permission-mode", conversation.claudeUsesTools ? "manual" : "dontAsk", "--disable-slash-commands",
      conversation.claudeHasSession == true ? "--resume" : "--session-id", session]
    if conversation.claudeUsesTools { args += ["--restricted", "--permission-prompt-tool", "stdio"] }
    if let model = conversation.modelID, !model.isEmpty { args += ["--model", model] }
    if let effort = conversation.reasoningEffort, !effort.isEmpty { args += ["--effort", effort] }
    return args
  }
  public static func input(_ conversation: Conversation) throws -> JSON {
    var content: [JSON] = []
    if !conversation.draft.isEmpty { content.append(.object(["type": .string("text"), "text": .string(conversation.draft)])) }
    for image in conversation.images {
      let data = try Data(contentsOf: URL(fileURLWithPath: image.path))
      content.append(.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string(image.mimeType), "data": .string(data.base64EncodedString())])]))
    }
    return .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .array(content)])])
  }
}
public struct ClaudeStreamState {
  public var text = ""
  public var model: String?
  public var started = false
  public var completed = false
  private let allowedTools: Set<String>
  public init(allowedTools: [String] = []) { self.allowedTools = Set(allowedTools) }
  public mutating func receive(_ event: JSON) throws {
    switch event["type"].text {
    case "system":
      if event["subtype"].text == "init" {
        guard Set(event["tools"].array.map(\.text)).isSubset(of: allowedTools), event["mcp_servers"].array.isEmpty else { throw ProtocolError.message("Claude 启用了本会话未授权的工具，连接已停止。") }
        started = true; model = event["model"].string
      }
    case "stream_event":
      if event["event"]["type"].text == "content_block_delta", event["event"]["delta"]["type"].text == "text_delta" { text += event["event"]["delta"]["text"].text }
    case "assistant":
      let full = event["message"]["content"].array.filter { $0["type"].text == "text" }.map { $0["text"].text }.joined()
      if !full.isEmpty { text = full }
      model = event["message"]["model"].string ?? model
    case "result":
      guard !event["is_error"].bool, event["subtype"].text == "success" else {
        let reason = event["result"].string ?? event["errors"].array.map(\.text).joined(separator: "\n")
        throw ProtocolError.message(reason.isEmpty ? "Claude 请求失败；请检查官方登录、网络和额度。" : reason)
      }
      if let result = event["result"].string, !result.isEmpty { text = result }
      completed = true
    default: break
    }
  }
}
