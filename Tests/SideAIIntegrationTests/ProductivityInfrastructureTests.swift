import XCTest
import SideAICore
import SideAIRemote
@testable import SideAI

final class ProductivityInfrastructureTests: XCTestCase {
  @MainActor func testQueuePausesAfterBackendFailureAndDoesNotSendNextJob() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory); defer { store.shutdown() }
    store.settings.connectedAgentIDs = [ConnectionRoute.codex.id]; store.newConversation(route: .codex)
    let source = store.selectedID!
    store.mutate(source) { $0.draft = "first" }; store.enqueueSelected()
    store.mutate(source) { $0.draft = "second" }; store.enqueueSelected()
    let second = store.productivitySettings.queue.last!.id
    // Mark the UI ready without attaching any transport. RPC must fail locally; no CLI is started.
    store.ready = true; store.startQueue()
    try await Task.sleep(nanoseconds: 650_000_000)
    XCTAssertFalse(store.queueRunning); XCTAssertEqual(store.productivitySettings.queue.map(\.id), [second])
    XCTAssertEqual(store.state.conversations.first(where: { $0.id == second })?.status, .idle)
    XCTAssertFalse(store.connecting)
  }
  func testStagingDoesNotReplaceDurableSnapshotUntilCommit() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = Persistence(directory: directory)
    var old = Conversation(cwd: directory.path); old.title = "old"
    try persistence.save(Snapshot(conversations: [old], selectedID: old.id))
    var newer = old; newer.title = "new"
    let file = try SnapshotStaging.stage(Snapshot(conversations: [newer], selectedID: newer.id), directory: directory)
    XCTAssertEqual(try persistence.load()?.conversations[0].title, "old")
    try SnapshotStaging.commit(file, directory: directory)
    XCTAssertEqual(try persistence.load()?.conversations[0].title, "new")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
  @MainActor func testDeferredSnapshotCannotOverwriteExplicitSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory); defer { store.shutdown() }
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let id = store.selectedID!
    store.mutate(id) { $0.draft = "older" }
    try await Task.sleep(nanoseconds: 410_000_000)
    store.mutate(id) { $0.draft = "latest" }; store.saveNow()
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(try store.persistence.load()?.conversations.first?.draft, "latest")
  }
  @MainActor func testFailedQueuePersistenceDoesNotRemovePendingTask() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory); defer { store.shutdown() }
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    store.mutate(store.selectedID!) { $0.draft = "must not send" }; store.enqueueSelected()
    let id = try XCTUnwrap(store.productivitySettings.queue.first?.id)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("state.json"))
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("state.json"), withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.commitQueuedDispatch(id))
    XCTAssertEqual(store.productivitySettings.queue.first?.id, id); XCTAssertTrue(store.apiTasks.isEmpty)
  }
  func testRemoteHistoryPagesAreBoundedAndHaveNoGap() throws {
    var c = Conversation(cwd: "/p"); c.items = (0..<100).map { TimelineItem(id: String($0), kind: "userMessage", text: String(repeating: "中", count: 5000)) }
    let first = try RemoteHistory.page(c, before: "40", requestID: "request1")
    XCTAssertEqual(first["items"].array.count, 30)
    XCTAssertEqual(first["items"].array.first?["id"].text, "10"); XCTAssertEqual(first["items"].array.last?["id"].text, "39")
    XCTAssertEqual(first["items"].array.first?["text"].text.count, 4000)
    XCTAssertTrue(first["hasMore"].bool); XCTAssertLessThan(first.pretty.utf8.count, 500_000)
    let end = try RemoteHistory.page(c, before: "10", requestID: "request2")
    XCTAssertEqual(end["items"].array.count, 10); XCTAssertFalse(end["hasMore"].bool)
    XCTAssertThrowsError(try RemoteHistory.page(c, before: "invalid", requestID: "request3"))
  }
  @MainActor func testRemoteHistoryRequiresAuthenticatedCommandAndDoesNotStartBackend() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    store.mutate(store.selectedID!) { $0.items = (0..<90).map { TimelineItem(id: String($0), kind: "userMessage", text: "message") } }
    let host = RemoteHost(store: store, loadSaved: false), device = UUID().uuidString, nonce = UUID().uuidString
    host.configuration = RemoteHostConfiguration(pairing: try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Fixture"), deviceID: device); host.enabled = true
    host.receive(.object(["kind": .string("hello"), "device": .string(device), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)]))
    var command: [String: RemoteValue] = ["kind": .string("command"), "op": .string("historyPage"), "conversation": .string(store.selectedID!.uuidString), "id": .string(UUID().uuidString), "nonce": .string(nonce), "challenge": .string("wrong"), "time": .number(Date().timeIntervalSince1970), "before": .string("30")]
    host.receive(.object(command)); XCTAssertEqual(host.snapshot()["historyPage"], .null)
    command["challenge"] = host.snapshot()["challenge"]; host.receive(.object(command))
    XCTAssertEqual(host.snapshot()["historyPage"]["items"].array.count, 30)
    XCTAssertTrue(store.apiTasks.isEmpty); XCTAssertFalse(store.connecting)
  }
}
