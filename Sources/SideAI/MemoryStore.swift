import Foundation
import SideAICore

extension SessionStore {
  func memoryEnabled(for conversation: Conversation) -> Bool {
    settings.crossConversationMemory != false && conversation.memoryEnabled != false
  }
  func usesMemoryTools(for conversation: Conversation) -> Bool {
    conversation.engine == .api && profiles.first(where: { $0.id == conversation.profileID })?.format == .responses && memoryEnabled(for: conversation)
  }
  func memoryContext(for conversation: Conversation) async -> MemoryContext {
    guard memoryEnabled(for: conversation) else { return MemoryContext() }
    let history = memoryHistory(for: conversation), notes = memoryNotes(for: conversation)
    if usesMemoryTools(for: conversation) { return MemoryContext(notes: String(notes.prefix(2000))) }
    return await Task.detached(priority: .userInitiated) {
      ConversationMemory.retrieve(query: conversation.draft, current: conversation, conversations: history, notes: notes)
    }.value
  }
  func executeMemoryTool(_ name: String, arguments: String, conversationID: UUID) async throws -> JSON {
    try Task.checkCancellation()
    guard let c = state.conversations.first(where: { $0.id == conversationID }), usesMemoryTools(for: c) else {
      return .object(["error": .string("本会话的历史访问已关闭")])
    }
    let history = memoryHistory(for: c)
    let task = Task.detached(priority: .userInitiated) { try MemoryTools.execute(name: name, arguments: arguments, current: c, conversations: history) }
    do {
      let (result, sources) = try await task.value
      try Task.checkCancellation()
      guard let latest = state.conversations.first(where: { $0.id == conversationID }), usesMemoryTools(for: latest),
        sources.allSatisfy({ source in memoryHistory(for: latest).contains { $0.id.uuidString == source.id && $0.memoryExcluded != true } }) else {
        return .object(["error": .string("历史访问设置已更改，请重新查询")])
      }
      mutate(conversationID) { conversation in
        var memory = conversation.lastMemory ?? MemoryContext()
        for source in sources {
          if let i = memory.sources.firstIndex(where: { $0.id == source.id }) { memory.sources[i] = source }
          else { memory.sources.append(source) }
        }
        conversation.lastMemory = memory
        if let i = conversation.items.lastIndex(where: { $0.kind == "userMessage" }) { conversation.items[i].memory = memory }
      }
      return result
    } catch is CancellationError { throw CancellationError() }
    catch { return .object(["error": .string("历史查询参数无效或会话不可访问，请调整查询。")]) }
  }
}
