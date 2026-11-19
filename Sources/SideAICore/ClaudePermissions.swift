import Foundation

public struct ClaudeApproval: Identifiable {
  public let id: String
  public let conversationID: UUID
  public let tool: String
  public let input: JSON
  public let cwd: String
}
public enum ClaudePermissions {
  public static func tools(for conversation: Conversation) -> [String] {
    guard conversation.claudeUsesTools else { return [] }
    return ["default"] // Official CLI built-ins; native permission rules decide which calls prompt.
  }
  public static func approval(event: JSON, conversation: Conversation) -> ClaudeApproval? {
    guard event["type"].text == "control_request", event["request"]["subtype"].text == "can_use_tool",
          let id = event["request_id"].string, conversation.claudeUsesTools, !event["request"]["tool_name"].text.isEmpty else { return nil }
    return ClaudeApproval(id: id, conversationID: conversation.id, tool: event["request"]["tool_name"].text,
                          input: event["request"]["input"], cwd: conversation.cwd)
  }
  public static func reply(id: String, input: JSON, allow: Bool) -> JSON {
    .object(["type": .string("control_response"), "response": .object([
      "subtype": .string("success"), "request_id": .string(id),
      "response": allow ? .object(["behavior": .string("allow"), "updatedInput": input]) : .object(["behavior": .string("deny"), "message": .string("用户未批准本次操作。")])])
    ])
  }
}
