import Foundation

public enum ChatGPTImport {
  public static func parse(_ data: Data, cwd: String) throws -> [Conversation] {
    guard data.count <= 100 * 1024 * 1024 else { throw ProtocolError.message("导出文件超过 100 MB，请拆分后导入") }
    let root = try JSONDecoder().decode(JSON.self, from: data)
    guard case .array(let exports) = root, exports.count <= 20_000 else { throw ProtocolError.message("请选择 ChatGPT 导出的 conversations.json（会话数组）") }
    var result: [Conversation] = []
    for raw in exports {
      guard let remoteID = raw["id"].string ?? raw["conversation_id"].string,
        case .object(let mapping) = raw["mapping"] else { continue }
      // Follow only the selected branch, never combine alternative answers into one transcript.
      var chain: [JSON] = [], seen = Set<String>()
      var cursor = raw["current_node"].string
      if cursor == nil {
        cursor = mapping.filter { $0.value["children"].array.isEmpty }.max { a,b in
          a.value["message"]["create_time"].numberValue < b.value["message"]["create_time"].numberValue
        }?.key
      }
      while let nodeID = cursor, let node = mapping[nodeID], seen.insert(nodeID).inserted {
        chain.append(node["message"]); cursor = node["parent"].string
      }
      var c = Conversation(cwd: cwd); c.backend = .chatgptArchive; c.importID = "chatgpt:" + remoteID
      c.originCategory = "chatgpt"; c.imported = true; c.title = raw["title"].string ?? "ChatGPT 会话"
      for m in chain.reversed() {
        let role = m["author"]["role"].text
        guard ["user", "assistant"].contains(role), !m["metadata"]["is_visually_hidden_from_conversation"].bool else { continue }
        let parts = m["content"]["parts"].array
        var text = parts.compactMap { $0.string }.joined(separator: "\n")
        if parts.contains(where: { $0["content_type"].text == "image_asset_pointer" }) { text += "\n[原会话图片未包含在此 JSON 导出中]" }
        if !text.isEmpty { c.items.append(TimelineItem(id: m["id"].string ?? UUID().uuidString, kind: role == "user" ? "userMessage" : "agentMessage", text: text)) }
      }
      c.status = .completed
      let time = raw["update_time"].numberValue; if time > 0 { c.updatedAt = Date(timeIntervalSince1970: time) }
      result.append(c)
    }
    guard !result.isEmpty else { throw ProtocolError.message("文件中没有可识别的 ChatGPT 会话") }
    return result
  }
}
extension JSON {
  public var numberValue: Double { if case .number(let n) = self { return n }; return 0 }
}
