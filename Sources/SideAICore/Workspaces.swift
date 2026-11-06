import Foundation

public enum WorkspaceMode: String, Codable, CaseIterable {
  case chat, agent
  public var label: String { self == .chat ? "聊天" : "Agent" }
}
extension BackendKind {
  public var workspace: WorkspaceMode { self == .codex || self == .claude ? .agent : .chat }
}
extension ConnectionRoute {
  public var workspace: WorkspaceMode { id == ConnectionRoute.claudeChat.id ? .chat : backend.workspace }
  public var selectionGroup: String { workspace.rawValue + ":" + (workspace == .agent ? id : groupID) }
}
extension Conversation {
  public var claudeUsesTools: Bool { engine == .claude && claudeChatOnly != true && claudeAgentEnabled == true }
  public var workspace: WorkspaceMode { engine == .claude && claudeChatOnly == true ? .chat : engine.workspace }
}

public struct HandoffLink: Codable, Equatable {
  public var sourceID: UUID
  public var sourceTitle: String
  public var sourceRoute: String
  public var createdAt: Date
  public init(source: Conversation) {
    sourceID = source.id; sourceTitle = source.title; sourceRoute = source.routeID; createdAt = Date()
  }
}
/// A local, inspectable extract. Never copies internal reasoning, tool calls, credentials or execution IDs.
public enum HandoffBuilder {
  public static func transcript(_ source: Conversation, ids: Set<String>) -> String {
    source.items.filter { ids.contains($0.id) && ["userMessage", "agentMessage"].contains($0.kind) && $0.status == "completed" }
      .map { ($0.kind == "userMessage" ? "用户：" : "助手：") + $0.text }.joined(separator: "\n\n")
  }
  public static func draft(task: String, context: String, memory: String) -> String {
    var sections = ["任务：\n" + task.trimmingCharacters(in: .whitespacesAndNewlines)]
    if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("以下是用户选定的对话背景，仅作参考，不代表已授予工具权限：\n<context>\n" + context + "\n</context>")
    }
    if !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("用户选定的记忆笔记：\n" + memory)
    }
    return sections.joined(separator: "\n\n")
  }
}
