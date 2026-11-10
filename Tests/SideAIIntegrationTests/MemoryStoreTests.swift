import XCTest
import SideAICore
@testable import SideAI
final class MemoryStoreTests: XCTestCase {
  @MainActor func testDefaultOnSwitchesNotesExclusionAndAccountPrompt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    var old = Conversation(cwd: dir.path); old.backend = .chatgptArchive; old.title = "SQL"; old.items = [TimelineItem(kind: "agentMessage", text: "SELECT b.TRACE_ID FROM b")]
    var current = Conversation(cwd: dir.path); current.draft = "之前 SQL 的 TRACE_ID"; current.backend = .accountRuntime
    store.state.conversations = [old, current]; store.settings.sharedMemory = "喜欢中文回答"
    var result = await store.memoryContext(for: current)
    XCTAssertEqual(result.sources.count, 1); XCTAssertEqual(result.notes, "喜欢中文回答")
    XCTAssertTrue(try AccountClient.prompt(current, memory: result).pretty.contains("SELECT b.TRACE_ID"))
    current.memoryEnabled = false; result = await store.memoryContext(for: current); XCTAssertTrue(result.isEmpty)
    current.memoryEnabled = true; store.settings.crossConversationMemory = false
    result = await store.memoryContext(for: current); XCTAssertTrue(result.isEmpty)
    store.settings.crossConversationMemory = true; store.settings.sharedMemory = ""; store.state.conversations[0].memoryExcluded = true
    result = await store.memoryContext(for: current); XCTAssertTrue(result.isEmpty)
  }
  @MainActor func testSendImmediatelyShowsMessageAndStopDuringMemoryDoesNotDispatch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    var p = ProviderKind.deepseek.preset(); p.defaultModel = "test"
    store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let id = try XCTUnwrap(store.selectedID)
    store.mutate(id) { $0.draft = "之前的 SQL" }
    store.send()
    XCTAssertEqual(store.selected?.items.last?.text, "之前的 SQL")
    XCTAssertEqual(store.selected?.draft, ""); XCTAssertEqual(store.selected?.status, .running)
    XCTAssertTrue(store.preparingMemory)
    store.mutate(id) { $0.draft = "下一条草稿" }
    store.interrupt(); await store.memoryPreparationTask?.value
    XCTAssertEqual(store.selected?.status, .interrupted); XCTAssertEqual(store.selected?.draft, "下一条草稿")
    XCTAssertEqual(store.selected?.items.count, 1); XCTAssertTrue(store.apiTasks.isEmpty); XCTAssertNil(store.banner)
    XCTAssertFalse(store.isBusy)
  }

}
