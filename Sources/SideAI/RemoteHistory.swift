import Foundation
import SideAICore
import SideAIRemote

enum RemoteHistory {
  static func page(_ conversation: Conversation, before: String, requestID: String) throws -> RemoteValue {
    let end: Int
    if before.isEmpty { end = conversation.items.count }
    else if let index = conversation.items.firstIndex(where: { $0.id == before }) { end = index }
    else { throw RemoteError.message("历史位置已变化，请重新打开会话") }
    let start = max(0, end - 30)
    let items: [RemoteValue] = conversation.items[start..<end].map { item in
      let text = item.text.isEmpty ? item.detail : item.text
      return .object(["id": .string(item.id), "role": .string(item.kind), "text": .string(String(text.prefix(4000))),
        "truncated": .bool(text.count > 4000), "status": .string(item.status)])
    }
    return .object(["request": .string(requestID), "conversation": .string(conversation.id.uuidString), "items": .array(items), "hasMore": .bool(start > 0)])
  }
}
