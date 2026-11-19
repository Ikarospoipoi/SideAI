import XCTest
@testable import SideAICore

final class ProductivityTests: XCTestCase {
  func testSearchFindsOldUnicodeMessagesAndRetainsIdentity() {
    var c = Conversation(cwd: "/project"); c.title = "数据库"
    let old = TimelineItem(kind: "agentMessage", text: "这是很早的 SQL：SELECT 用户名 FROM 用户")
    c.items = [old] + (0..<120).map { TimelineItem(kind: "userMessage", text: "后续消息 \($0)") }
    let hits = HistorySearch.search("select 用户名", conversations: [c])
    XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits.first?.messageID, old.id)
    XCTAssertEqual(hits.first?.conversationID, c.id); XCTAssertTrue(hits.first?.excerpt.contains("用户名") == true)
    XCTAssertTrue(HistorySearch.search("select 不存在", conversations: [c]).isEmpty)
  }
  func testSearchDoesNotReadToolLogsAndBoundsResults() {
    var c = Conversation(cwd: "/p"); c.items = [TimelineItem(kind: "commandExecution", text: "secret")]
    XCTAssertTrue(HistorySearch.search("secret", conversations: [c]).isEmpty)
    c.items = (0..<150).map { TimelineItem(kind: "userMessage", text: "匹配 \($0)") }
    XCTAssertEqual(HistorySearch.search("匹配", conversations: [c]).count, 100)
  }
  func testScopesExcludeOtherProjectsAndExcludedSources() {
    let current = Conversation(cwd: "/project/./one")
    var same = Conversation(cwd: "/project/one"), other = Conversation(cwd: "/project/two")
    var p = ConversationPreferences()
    XCTAssertEqual(ProjectHistory.eligible([same, other, current], current: current, preferences: p).map(\.id), [same.id])
    p.scope = .selected; p.sourceIDs = [other.id]
    XCTAssertEqual(ProjectHistory.eligible([same, other], current: current, preferences: p).map(\.id), [other.id])
    other.memoryExcluded = true; XCTAssertTrue(ProjectHistory.eligible([same, other], current: current, preferences: p).isEmpty)
    p.scope = .all; same.memoryExcluded = true
    XCTAssertTrue(ProjectHistory.eligible([same, other], current: current, preferences: p).isEmpty)
  }
  func testContextDropsWholeOldTurnsWithoutChangingOriginal() throws {
    let old = TimelineItem(kind: "userMessage", text: String(repeating: "旧", count: 700))
    let answer = TimelineItem(kind: "agentMessage", text: String(repeating: "答", count: 200))
    let latest = TimelineItem(kind: "userMessage", text: String(repeating: "新", count: 200))
    let history = [old, answer, latest]
    var p = ConversationPreferences(); p.contextBudget = 1000
    let plan = try ContextPlanner.plan(history, preferences: p)
    XCTAssertEqual(plan.items.map(\.id), [latest.id]); XCTAssertEqual(plan.omitted, 2)
    XCTAssertEqual(history.count, 3)
  }
  func testContextCountsImagesSummaryAndRefusesOversizedLatestInput() throws {
    var latest = TimelineItem(kind: "userMessage", text: "图片")
    latest.attachments = [ImageAttachment(id: UUID(), path: "/unused", name: "image", mimeType: "image/png")]
    var p = ConversationPreferences(); p.contextBudget = 1000
    XCTAssertThrowsError(try ContextPlanner.plan([latest], preferences: p))
    p.contextBudget = 4000; p.summary = "重要结论"
    let plan = try ContextPlanner.plan([latest], preferences: p, reserve: 1024)
    XCTAssertTrue(plan.items[0].text.contains("重要结论")); XCTAssertGreaterThan(plan.estimatedTokens, 2600)
    p.summary = String(repeating: "长", count: 4000)
    XCTAssertThrowsError(try ContextPlanner.plan([latest], preferences: p))
  }
  func testBranchNeverCopiesExecutionIdentityOrToolState() {
    var source = Conversation(cwd: "/project"); source.backend = .codex; source.threadID = "existing"; source.turnID = "active"
    source.status = .completed
    source.memoryEnabled = false; source.memoryExcluded = true
    let user = TimelineItem(kind: "userMessage", text: "原始要求")
    source.items = [user, TimelineItem(kind: "commandExecution", text: "do-not-copy"), TimelineItem(kind: "agentMessage", text: "稍后的回答")]
    let branch = ConversationCopy.branch(source, through: user.id)
    XCTAssertNotEqual(branch.id, source.id); XCTAssertNil(branch.threadID); XCTAssertNil(branch.turnID)
    XCTAssertTrue(branch.items.isEmpty); XCTAssertTrue(branch.draft.contains("原始要求"))
    XCTAssertFalse(branch.draft.contains("do-not-copy")); XCTAssertFalse(branch.draft.contains("稍后的回答"))
    XCTAssertEqual(branch.status, .idle)
    XCTAssertEqual(branch.memoryEnabled, false); XCTAssertEqual(branch.memoryExcluded, true)
  }
  func testChatBranchAndExportOnlyCopyVisibleContent() {
    var source = Conversation(cwd: "/p"); source.backend = .api; source.profileID = UUID()
    source.items = [TimelineItem(kind: "userMessage", text: "你好"), TimelineItem(kind: "reasoning", text: "hidden")]
    let copy = ConversationCopy.branch(source)
    XCTAssertEqual(copy.profileID, source.profileID); XCTAssertEqual(copy.items.count, 1)
    let text = ConversationCopy.transcript(source.items, markdown: true)
    XCTAssertTrue(text.contains("## 用户")); XCTAssertFalse(text.contains("hidden"))
  }
  func testPreferencesAndQueueRoundTripWithLegacyDefaults() throws {
    var settings = AppSettings(); var productivity = ProductivitySettings()
    let id = UUID(); productivity.queue = [QueuedConversation(id: id)]; productivity.conversations[id.uuidString] = ConversationPreferences()
    settings.productivity = productivity
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.productivity?.queue.first?.id, id)
    var old = AppSettings(); old.productivity = nil
    XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(old)).productivity)
  }
}
