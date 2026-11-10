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
}
