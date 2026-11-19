import XCTest
import SideAICore
@testable import SideAI

final class ProductivityStoreTests: XCTestCase {
  @MainActor private func withStore(_ work: (SessionStore) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    try work(store)
  }
  @MainActor func testQueueCreatesIndependentDraftAndStartsPausedAfterRestart() throws {
    try withStore { store in
      let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
      let source = store.selectedID!; store.mutate(source) { $0.draft = "处理任务" }
      store.enqueueSelected()
      let id = try XCTUnwrap(store.productivitySettings.queue.first?.id)
      XCTAssertNotEqual(source, id); XCTAssertEqual(store.selected?.draft, "")
      XCTAssertEqual(store.state.conversations.first(where: { $0.id == id })?.draft, "处理任务")
      XCTAssertFalse(store.queueRunning); XCTAssertTrue(store.apiTasks.isEmpty)
      let restored = SessionStore(directory: store.persistence.directory); defer { restored.shutdown() }
      XCTAssertEqual(restored.productivitySettings.queue.first?.id, id); XCTAssertFalse(restored.queueRunning)
      restored.removeQueued(id); XCTAssertTrue(restored.productivitySettings.queue.isEmpty)
      XCTAssertNotNil(restored.state.conversations.first(where: { $0.id == id }))
    }
  }
  @MainActor func testQueueWithDisconnectedCodexNeverStartsCLI() throws {
    try withStore { store in
      store.settings.connectedAgentIDs = [ConnectionRoute.codex.id]; store.newConversation(route: .codex)
      store.mutate(store.selectedID!) { $0.draft = "排队测试" }; store.enqueueSelected(); store.startQueue()
      XCTAssertFalse(store.queueRunning); XCTAssertFalse(store.connecting); XCTAssertEqual(store.productivitySettings.queue.count, 1)
      XCTAssertTrue(store.banner?.contains("先连接 Codex") == true)
    }
  }
  @MainActor func testProjectRestoresDefaultsWithoutSending() throws {
    try withStore { store in
      let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
      let id = store.selectedID!
      store.mutate(id) { $0.cwd = "/project/a"; $0.modelID = "chosen" }
      store.updatePreferences(id) { $0.scope = .selected; $0.pinnedNotes = "项目背景" }
      store.saveProject(store.selected!, name: "项目 A", prompt: "解释这个项目")
      store.openProject(store.productivitySettings.projects[0])
      XCTAssertNotEqual(store.selectedID, id); XCTAssertEqual(store.selected?.cwd, "/project/a")
      XCTAssertEqual(store.selected?.modelID, "chosen"); XCTAssertEqual(store.selected?.draft, "解释这个项目")
      XCTAssertEqual(store.preferences(for: store.selected!).pinnedNotes, "项目背景"); XCTAssertTrue(store.apiTasks.isEmpty)
    }
  }
  @MainActor func testMemoryScopeAndQuickTextRespectCurrentConversation() throws {
    try withStore { store in
      let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
      store.mutate(store.selectedID!) { $0.cwd = "/project/a" }
      var other = Conversation(cwd: "/project/b"); other.backend = .api; other.profileID = p.id
      store.state.conversations.append(other)
      XCTAssertTrue(store.memoryHistory(for: store.selected!).isEmpty)
      store.updatePreferences(store.selectedID!) { $0.scope = .all }
      XCTAssertEqual(store.memoryHistory(for: store.selected!).count, 1)
      store.appendQuickText("外部文本", instruction: "翻译")
      XCTAssertTrue(store.selected?.draft.contains("外部文本") == true); XCTAssertTrue(store.apiTasks.isEmpty)
    }
  }
  func testTextAttachmentRejectsBinaryAndOversizedFiles() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0, 1, 2]).write(to: url); XCTAssertThrowsError(try TextAttachment.read(url))
    try Data(repeating: 65, count: 1_000_001).write(to: url); XCTAssertThrowsError(try TextAttachment.read(url))
    try "日志：错误 🌿".write(to: url, atomically: true, encoding: .utf8)
    XCTAssertTrue(try TextAttachment.read(url).contains("日志：错误 🌿"))
  }
  func testMarkdownSeparatesTablesCodeAndStreamingIncompleteFence() {
    let blocks = MarkdownSections.parse("# 标题\n| 列一 | 列二 |\n| --- | --- |\n| A | B |\n```swift\nlet x = 1")
    XCTAssertEqual(blocks.count, 3)
    guard case .table(let rows) = blocks[1], case .code(let language, let source) = blocks[2] else { return XCTFail("Expected table and code") }
    XCTAssertEqual(rows, [["列一", "列二"], ["A", "B"]]); XCTAssertEqual(language, "swift"); XCTAssertEqual(source, "let x = 1")
  }
}
