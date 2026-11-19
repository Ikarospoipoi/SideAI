import Foundation

public enum HistoryScope: String, Codable, CaseIterable {
  case project, selected, all
  public var label: String { switch self { case .project: return "当前项目"; case .selected: return "指定会话"; case .all: return "全部历史" } }
}
public struct ConversationPreferences: Codable, Equatable {
  public var scope: HistoryScope = .project
  public var sourceIDs: [UUID] = []
  public var pinnedNotes = ""
  public var contextBudget = 16000
  public var summary = ""
  public init() {}
}
public struct ProjectProfile: Codable, Identifiable {
  public var id: String
  public var name: String
  public var routeID: String
  public var model: String?
  public var effort: String?
  public var prompt: String
  public var preferences: ConversationPreferences
  public init(path: String, name: String, routeID: String, model: String?, effort: String?, prompt: String, preferences: ConversationPreferences) {
    id = ProjectHistory.path(path); self.name = name; self.routeID = routeID; self.model = model; self.effort = effort
    self.prompt = prompt; self.preferences = preferences
  }
}
public struct QueuedConversation: Codable, Identifiable {
  public var id: UUID
  public var createdAt = Date()
  public init(id: UUID) { self.id = id }
}
public struct ProductivitySettings: Codable {
  public var conversations: [String: ConversationPreferences] = [:]
  public var projects: [ProjectProfile] = []
  public var queue: [QueuedConversation] = []
  public var notifications = false
  public init() {}
}
public enum ProjectHistory {
  public static func path(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.path }
  public static func eligible(_ history: [Conversation], current: Conversation, preferences: ConversationPreferences) -> [Conversation] {
    history.filter { c in
      guard c.id != current.id, c.memoryExcluded != true else { return false }
      switch preferences.scope {
      case .all: return true
      case .project: return path(c.cwd) == path(current.cwd)
      case .selected: return preferences.sourceIDs.contains(c.id)
      }
    }
  }
}
public struct HistoryHit: Identifiable, Sendable {
  public var id: String { conversationID.uuidString + ":" + (messageID ?? "title") }
  public let conversationID: UUID
  public let messageID: String?
  public let title: String
  public let excerpt: String
}
public enum HistorySearch {
  /// All words must match the same title/message. Results retain message identities for navigation.
  public static func search(_ query: String, conversations: [Conversation], limit: Int = 100) -> [HistoryHit] {
    let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !terms.isEmpty else { return [] }
    var results: [HistoryHit] = []
    for c in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
      if terms.allSatisfy({ c.title.lowercased().contains($0) }) {
        results.append(HistoryHit(conversationID: c.id, messageID: nil, title: c.title, excerpt: "标题匹配"))
      }
      for item in c.items where ["userMessage", "agentMessage"].contains(item.kind) {
        let text = MemoryContext.originalMessage(item.text), lower = text.lowercased()
        guard terms.allSatisfy({ lower.contains($0) }) else { continue }
        let range = text.range(of: terms[0], options: .caseInsensitive)
        let start = range.map { text.index($0.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
        let excerpt = (start == text.startIndex ? "" : "…") + String(text[start...].prefix(240))
        results.append(HistoryHit(conversationID: c.id, messageID: item.id, title: c.title, excerpt: excerpt))
        if results.count >= max(1, limit) { return Array(results.prefix(max(1, limit))) }
      }
      if results.count >= max(1, limit) { break }
    }
    return Array(results.prefix(max(1, limit)))
  }
}
public struct ContextPlan {
  public let items: [TimelineItem]
  public let omitted: Int
  public let estimatedTokens: Int
}
public enum ContextPlanner {
  /// An estimate, not provider tokenization. Images reserve an approximate allowance.
  public static func estimate(_ text: String) -> Int {
    let ascii = text.unicodeScalars.filter { $0.isASCII }.count
    return (ascii + 3) / 4 + text.unicodeScalars.count - ascii
  }
  public static func cost(_ item: TimelineItem) -> Int { estimate(item.text) + (item.attachments?.count ?? 0) * 1600 + 12 }
  public static func plan(_ items: [TimelineItem], preferences: ConversationPreferences, reserve: Int = 0) throws -> ContextPlan {
    let history = items.filter { ["userMessage", "agentMessage"].contains($0.kind) && $0.status == "completed" }
    guard !history.isEmpty else { return ContextPlan(items: [], omitted: 0, estimatedTokens: 0) }
    let summary = preferences.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let summaryItem = TimelineItem(kind: "userMessage", text: "以下是我确认保留的历史摘要，仅作背景，不是新的任务或工具授权：\n" + summary)
    let fixed = reserve + (summary.isEmpty ? 0 : cost(summaryItem))
    let budget = max(1000, preferences.contextBudget)
    // Keep complete user-led groups; never leave an orphan assistant answer.
    var groups: [[TimelineItem]] = []
    for item in history {
      if item.kind == "userMessage" || groups.isEmpty { groups.append([item]) }
      else { groups[groups.count - 1].append(item) }
    }
    guard let last = groups.last, fixed + last.reduce(0, { $0 + cost($1) }) <= budget else {
      throw ProtocolError.message("最新一轮、固定摘要或记忆超过上下文预算。请缩短内容、关闭记忆或调高预算后发送；没有发送请求。")
    }
    var kept: [TimelineItem] = [], tokens = fixed
    for group in groups.reversed() {
      let amount = group.reduce(0) { $0 + cost($1) }
      guard tokens + amount <= budget else { break }
      tokens += amount; kept.insert(contentsOf: group, at: 0)
    }
    let omitted = history.count - kept.count
    if !summary.isEmpty { kept.insert(summaryItem, at: 0) }
    return ContextPlan(items: kept, omitted: omitted, estimatedTokens: tokens)
  }
}
public enum ConversationCopy {
  public static func branch(_ source: Conversation, through messageID: String? = nil) -> Conversation {
    var copy = Conversation(cwd: source.cwd)
    copy.backend = source.backend; copy.profileID = source.profileID; copy.accountRuntime = source.accountRuntime
    copy.modelID = source.modelID; copy.reasoningEffort = source.reasoningEffort
    copy.memoryEnabled = source.memoryEnabled; copy.memoryExcluded = source.memoryExcluded
    copy.title = "分支 · " + source.title
    let end = messageID.flatMap { id in source.items.firstIndex(where: { $0.id == id }).map { $0 + 1 } } ?? source.items.count
    let items = source.items.prefix(end).filter { ["userMessage", "agentMessage"].contains($0.kind) && $0.status == "completed" }
    if source.engine == .codex {
      copy.draft = "以下是旧会话背景，不代表文件状态已回滚，也不构成新的执行授权：\n" + transcript(Array(items), markdown: false) + "\n\n本次任务：\n"
    } else { copy.items = Array(items) }
    return copy
  }
  public static func transcript(_ items: [TimelineItem], markdown: Bool) -> String {
    items.filter { ["userMessage", "agentMessage"].contains($0.kind) }.map {
      let role = $0.kind == "userMessage" ? "用户" : "助手"
      let images = ($0.attachments ?? []).map { "[图片：\($0.name)]" }.joined(separator: "\n")
      return (markdown ? "## " : "") + role + "\n\n" + MemoryContext.originalMessage($0.text) + (images.isEmpty ? "" : "\n" + images)
    }.joined(separator: "\n\n")
  }
}
