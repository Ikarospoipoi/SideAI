import XCTest
import SideAICore
@testable import SideAI

final class RouteStoreTests: XCTestCase {
  @MainActor func testConnectionSwitchRestoresDraftAndSelectionDespiteNewerSyncedHistory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir)
    defer { store.shutdown() }
    let first = ProviderKind.deepseek.preset(), second = ProviderKind.kimi.preset()
    store.settings.apiProfiles = [first, second]
    store.newConversation(route: .api(first))
    let original = try XCTUnwrap(store.selectedID)
    store.mutate(original) { $0.draft = "只属于 DeepSeek 的草稿"; $0.modelID = "chosen-model" }
    store.switchConnection(.api(second))
    XCTAssertEqual(store.selected?.draft, "")
    var imported = Conversation(cwd: dir.path); imported.backend = .api; imported.profileID = first.id; imported.updatedAt = Date().addingTimeInterval(30)
    store.state.conversations.append(imported)
    store.switchConnection(.api(first))
    XCTAssertEqual(store.selectedID, original)
    XCTAssertEqual(store.selected?.draft, "只属于 DeepSeek 的草稿")
    XCTAssertEqual(store.selected?.modelID, "chosen-model")
    XCTAssertEqual(store.state.conversations.first { $0.profileID == second.id }?.draft, "")
  }
  @MainActor func testDuplicateAndExistingConversationEndpointChangesAreRejected() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    store.settings.connectedAgentIDs = [ConnectionRoute.codex.id]
    _ = store.activate(.codex)
    let p = ProviderKind.openai.preset()
    try store.saveProfile(p, key: "")
    XCTAssertThrowsError(try store.saveProfile(ProviderKind.openai.preset(), key: ""))
    store.newConversation(route: .api(p))
    XCTAssertTrue(store.isRouteActive(.codex))
    var changed = p; changed.baseURL = "https://another.example/v1"
    XCTAssertThrowsError(try store.saveProfile(changed, key: ""))
    store.mutate(store.selectedID!) { $0.status = .running }
    XCTAssertTrue(store.activate(.codex))
    XCTAssertTrue(store.isRouteActive(.api(p)))
  }
}
