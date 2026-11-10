import Foundation
import SideAICore

extension SessionStore {
  func memoryEnabled(for conversation: Conversation) -> Bool {
    settings.crossConversationMemory != false && conversation.memoryEnabled != false
  }
  func memoryContext(for conversation: Conversation) async -> MemoryContext {
    guard memoryEnabled(for: conversation) else { return MemoryContext() }
    let history = state.conversations, notes = settings.sharedMemory ?? ""
    return await Task.detached(priority: .userInitiated) {
      ConversationMemory.retrieve(query: conversation.draft, current: conversation, conversations: history, notes: notes)
    }.value
  }
}
