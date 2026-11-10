import XCTest
import SideAICore
import SideAIRemote
@testable import SideAI

final class RemoteHostTests: XCTestCase {
  @MainActor func testRemoteCommandsRequirePairingFreshChallengeAndRevision() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    let profile = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [profile]; store.newConversation(route: .api(profile))
    let id = try XCTUnwrap(store.selectedID)
    let host = RemoteHost(store: store, loadSaved: false)
    let pairing = try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Test")
    let device = UUID().uuidString, nonce = UUID().uuidString
    host.configuration = RemoteHostConfiguration(pairing: pairing, deviceID: device, deviceName: "Test phone")
    host.enabled = true
    func hello(_ nonce: String) { host.receive(.object(["kind": .string("hello"), "device": .string(device), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)])) }
    hello(nonce)
    func request(model: String) -> [String: RemoteValue] {
      ["kind": .string("command"), "op": .string("configure"), "id": .string(UUID().uuidString), "time": .number(Date().timeIntervalSince1970), "nonce": .string(nonce), "challenge": host.snapshot()["challenge"], "conversation": .string(id.uuidString), "revision": .string(host.revision(store.selected!)), "model": .string(model), "effort": .string(""), "cwd": .string(store.scratch.path), "mode": .string("readOnly")]
    }
    var bad = request(model: "unauthorized"); bad["challenge"] = .string(UUID().uuidString); host.receive(.object(bad))
    XCTAssertNotEqual(store.selected?.modelID, "unauthorized")
    let valid = request(model: "accepted"); host.receive(.object(valid)); XCTAssertEqual(store.selected?.modelID, "accepted")
    var duplicate = valid; duplicate["model"] = .string("duplicate"); duplicate["revision"] = .string(host.revision(store.selected!)); host.receive(.object(duplicate)); XCTAssertEqual(store.selected?.modelID, "accepted")
    var stale = request(model: "stale"); stale["revision"] = .string("old"); host.receive(.object(stale)); XCTAssertEqual(store.selected?.modelID, "accepted")
    let beforeReconnect = request(model: "replayed"); hello(UUID().uuidString); host.receive(.object(beforeReconnect)); XCTAssertEqual(store.selected?.modelID, "accepted")
    host.enabled = false; host.receive(.object(request(model: "paused"))); XCTAssertEqual(store.selected?.modelID, "accepted")
    XCTAssertFalse(host.snapshot().pretty.contains(profile.baseURL), "No connection endpoints or credentials in phone state")
  }
  @MainActor func testUnapprovedPhoneCannotChangeConversation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    let host = RemoteHost(store: store, loadSaved: false)
    host.configuration = RemoteHostConfiguration(pairing: try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Test"))
    host.enabled = true
    let nonce = UUID().uuidString
    host.receive(.object(["kind": .string("hello"), "device": .string(UUID().uuidString), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)]))
    XCTAssertNotNil(host.pendingDevice)
    let count = store.state.conversations.count
    host.receive(.object(["kind": .string("command"), "op": .string("new"), "id": .string(UUID().uuidString), "nonce": .string(nonce), "challenge": host.snapshot()["challenge"], "route": .string("codex-local"), "time": .number(Date().timeIntervalSince1970)]))
    XCTAssertEqual(store.state.conversations.count, count)
  }
  @MainActor func testPhoneSendStopProtectsDesktopDraftAndDoesNotDuplicate() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    var p = ProviderKind.deepseek.preset(); p.defaultModel = "fixture"
    store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let id = try XCTUnwrap(store.selectedID), device = UUID().uuidString, nonce = UUID().uuidString
    let host = RemoteHost(store: store, loadSaved: false)
    host.configuration = RemoteHostConfiguration(pairing: try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Fixture"), deviceID: device)
    host.enabled = true
    host.receive(.object(["kind": .string("hello"), "device": .string(device), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)]))
    func command(_ op: String) -> [String: RemoteValue] {
      ["kind": .string("command"), "op": .string(op), "id": .string(UUID().uuidString), "time": .number(Date().timeIntervalSince1970), "nonce": .string(nonce), "challenge": host.snapshot()["challenge"], "conversation": .string(id.uuidString), "revision": .string(host.revision(store.selected!)), "text": .string("来自手机的下一步")]
    }
    store.mutate(id) { $0.draft = "电脑草稿" }
    host.receive(.object(command("send"))); XCTAssertEqual(store.selected?.draft, "电脑草稿"); XCTAssertTrue(store.selected!.items.isEmpty)
    store.mutate(id) { $0.draft = "" }
    let send = command("send"); host.receive(.object(send)); host.receive(.object(send))
    XCTAssertEqual(store.selected?.items.count, 1); XCTAssertEqual(store.selected?.items.last?.text, "来自手机的下一步")
    XCTAssertTrue(store.preparingMemory)
    host.receive(.object(command("stop"))); await store.memoryPreparationTask?.value
    XCTAssertEqual(store.selected?.status, .interrupted); XCTAssertTrue(store.apiTasks.isEmpty)
  }

  @MainActor func testChangedApprovalAndDisconnectedAgentCannotBeApproved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    store.settings.connectedAgentIDs = [ConnectionRoute.codex.id]
    store.newConversation(route: .codex)
    let id = try XCTUnwrap(store.selectedID)
    store.mutate(id) { $0.threadID = "fixture-thread"; $0.status = .awaitingApproval }
    let request = PendingRequest(requestID: .number(42), method: "item/commandExecution/requestApproval", params: .object(["threadId": .string("fixture-thread"), "command": .string("echo fixture")]), generation: store.state.generation)
    store.state.pending = [request]
    let host = RemoteHost(store: store, loadSaved: false), device = UUID().uuidString, nonce = UUID().uuidString
    host.configuration = RemoteHostConfiguration(pairing: try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Fixture"), deviceID: device)
    host.enabled = true
    host.receive(.object(["kind": .string("hello"), "device": .string(device), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)]))
    let row = try XCTUnwrap(host.snapshot()["approvals"].array.first)
    func approve(_ fingerprint: RemoteValue) { host.receive(.object(["kind": .string("command"), "op": .string("approve"), "id": .string(UUID().uuidString), "nonce": .string(nonce), "challenge": host.snapshot()["challenge"], "time": .number(Date().timeIntervalSince1970), "approval": row["id"], "fingerprint": fingerprint, "allow": .bool(true)])) }
    store.ready = true; approve(.string("stale-fingerprint")); XCTAssertFalse(store.state.pending[0].submitted)
    store.ready = false; approve(row["fingerprint"]); XCTAssertFalse(store.state.pending[0].submitted)
    store.ready = true; approve(row["fingerprint"]); XCTAssertTrue(store.state.pending[0].submitted)
    XCTAssertTrue(host.snapshot()["approvals"].array.isEmpty)
  }

}
