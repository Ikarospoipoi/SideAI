import XCTest
import SideAICore
@testable import SideAI

final class ConnectionManagementTests: XCTestCase {
  @MainActor func testDeleteCurrentAPIKeepsHistoryAndRestoresSameIdentity() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    let p = ProviderKind.deepseek.preset()
    store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let id = try XCTUnwrap(store.selectedID)
    store.mutate(id) { $0.draft = "未发出的草稿"; $0.items.append(TimelineItem(kind: "agentMessage", text: "已有回复")) }
    let before = try XCTUnwrap(store.selected)
    var deleted: UUID?
    try store.removeConnection(.api(p)) { deleted = $0 }
    XCTAssertEqual(deleted, p.id); XCTAssertTrue(store.profiles.isEmpty); XCTAssertNil(store.selectedID)
    XCTAssertFalse(store.activate(.api(p)))
    store.select(id); XCTAssertFalse(store.canSend); XCTAssertTrue(store.currentRoute.name.contains("已移除"))
    XCTAssertEqual(store.selected?.draft, before.draft); XCTAssertEqual(store.selected?.items, before.items)
    try store.restoreConnection(p.routeID)
    XCTAssertEqual(store.selectedProfile?.id, p.id); XCTAssertTrue(store.canSend)
    XCTAssertTrue((store.settings.removedAPIProfiles ?? []).isEmpty)
  }
  @MainActor func testDeletionFailureAndRunningTaskLeaveConnectionIntact() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    XCTAssertThrowsError(try store.removeConnection(.api(p)) { _ in throw CancellationError() })
    XCTAssertEqual(store.profiles, [p]); XCTAssertTrue(store.isRouteActive(.api(p)))
    store.preparingAPI = true
    XCTAssertThrowsError(try store.removeConnection(.api(p)) { _ in XCTFail("Busy deletion must not touch Keychain") })
    store.preparingAPI = false
  }
  @MainActor func testRemovedAgentSurvivesRestartAndMissingCredentialKeepsDraft() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir)
    store.settings.connectedAgentIDs = [ConnectionRoute.claude.id]
    try store.removeConnection(.claude)
    let restored = SessionStore(directory: dir); defer { restored.shutdown(); store.shutdown() }
    XCTAssertFalse(restored.routes.contains(.claude)); XCTAssertFalse(restored.activate(.claude))
    try restored.restoreConnection(ConnectionRoute.claude.id); XCTAssertTrue(restored.routes.contains(.claude))
    var p = ProviderKind.deepseek.preset(); p.defaultModel = "test"
    store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let id = try XCTUnwrap(store.selectedID); store.mutate(id) { $0.draft = "凭据失败时仍保留" }
    store.sendAPI(try XCTUnwrap(store.selected)); await store.apiTasks[id]?.value
    XCTAssertEqual(store.selected?.draft, "凭据失败时仍保留"); XCTAssertTrue(store.selected?.items.isEmpty == true)
    XCTAssertFalse(store.isBusy); XCTAssertTrue(store.apiClients.isEmpty); XCTAssertNotNil(store.banner)
  }
}
