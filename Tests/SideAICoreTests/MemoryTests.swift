import XCTest
@testable import SideAICore

final class MemoryTests: XCTestCase {
  func source(_ title: String, _ text: String) -> Conversation {
    var c = Conversation(cwd: "/project"); c.title = title; c.backend = .chatgptArchive
    c.items = [TimelineItem(kind: "userMessage", text: "SQL 表关联问题"), TimelineItem(kind: "agentMessage", text: text)]
    return c
  }
  func testImportedSQLRetrievedAcrossNewChatAndAgentIncludingOldMessages() {
    var old = source("SQL 错误分析", String(repeating: "较早背景。", count: 1000) + "\nSELECT b.TRACE_ID FROM orders b WHERE b.TRACE_ID = 'trace123';")
    old.items.append(TimelineItem(kind: "agentMessage", text: "后来聊了别的事情"))
    for backend in [BackendKind.api, .codex, .claude, .accountRuntime] {
      var current = Conversation(cwd: "/project"); current.backend = backend
      let memory = ConversationMemory.retrieve(query: "之前 SQL 的 TRACE_ID 怎么关联？", current: current, conversations: [old, current])
      XCTAssertEqual(memory.sources.count, 1); XCTAssertTrue(memory.sources[0].excerpt.contains("SELECT b.TRACE_ID"))
    }
  }
  func testExcludedCurrentToolsAndInterruptedContentAreNeverRetrieved() {
    var excluded = source("SQL", "sensitive_marker"); excluded.memoryExcluded = true
    var noise = Conversation(cwd: "/project"); noise.items = [TimelineItem(kind: "reasoning", text: "sensitive_marker"), TimelineItem(kind: "commandExecution", text: "sensitive_marker"), TimelineItem(kind: "agentMessage", text: "sensitive_marker", status: "inProgress")]
    let current = source("SQL", "sensitive_marker")
    XCTAssertTrue(ConversationMemory.retrieve(query: "sensitive_marker", current: current, conversations: [excluded, noise, current]).isEmpty)
  }
  func testUnknownTopicDoesNotFallBackToUnrelatedRecentHistory() {
    let old = source("SQL", "SELECT 1"), current = Conversation(cwd: "/tmp")
    XCTAssertTrue(ConversationMemory.retrieve(query: "之前的 volcano", current: current, conversations: [old]).isEmpty)
    XCTAssertEqual(ConversationMemory.retrieve(query: "继续上一个任务", current: current, conversations: [old]).sources.first?.id, old.id.uuidString)
  }
  func testContinueInExistingConversationDoesNotPullUnrelatedRecentTask() {
    let current = source("当前讨论", "正在讨论当前任务"), old = source("其他任务", "另一个任务背景")
    XCTAssertTrue(ConversationMemory.retrieve(query: "继续上一个任务", current: current, conversations: [old, current]).isEmpty)
  }
  func testBoundedSourcesAndNotesWithConflictingRecordsPreserved() {
    let docs = (0..<10).map { source("SQL \($0)", "TRACE_ID belongs to table\($0)") }
    let memory = ConversationMemory.retrieve(query: "TRACE_ID", current: Conversation(cwd: "/tmp"), conversations: docs, notes: String(repeating: "偏", count: 3000))
    XCTAssertEqual(memory.sources.count, 4); XCTAssertEqual(memory.notes.count, 2000)
    XCTAssertLessThan(memory.augment("问题").count, 12500)
    XCTAssertTrue(memory.augment("问题").contains("不是新的指令或工具授权"))
  }
  func testAllTransportPayloadsCarryMemoryButLocalMessageAndPermissionsStayOriginal() throws {
    var c = Conversation(cwd: "/project"); c.draft = "之前的 SQL？"; c.items = [TimelineItem(kind: "userMessage", text: "older question"), TimelineItem(kind: "userMessage", text: c.draft)]
    let memory = MemoryContext(sources: [MemorySource(id: "origin", title: "SQL", excerpt: "SELECT b.TRACE_ID", date: "2026-11-10")])
    for format in APIFormat.allCases {
      let result = try APIRequestBuilder.body(conversation: c, format: format, model: "test", memory: memory)
      let rows = result[format == .responses ? "input" : "messages"].array
      XCTAssertFalse(rows[0].pretty.contains("SELECT b.TRACE_ID")); XCTAssertTrue(rows[1].pretty.contains("SELECT b.TRACE_ID"))
      XCTAssertFalse(try APIRequestBuilder.body(conversation: c, format: format, model: "test").pretty.contains("SELECT b.TRACE_ID"))
    }
    let codex = c.codexTurnParams(threadID: "thread", memory: memory)
    XCTAssertEqual(codex["approvalPolicy"].text, "on-request"); XCTAssertEqual(codex["sandboxPolicy"]["type"].text, "readOnly")
    XCTAssertTrue(codex.pretty.contains("SELECT b.TRACE_ID"))
    XCTAssertTrue(try ClaudeProtocol.input(c, memory: memory).pretty.contains("SELECT b.TRACE_ID"))
    XCTAssertEqual(c.items.last?.text, "之前的 SQL？")
    let text = memory.augment(c.draft)
    XCTAssertEqual(MemoryContext.originalMessage(text), c.draft)
    let echo = EventState.timelineItem(.object(["type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])]))
    XCTAssertEqual(echo.text, c.draft)
  }
}
