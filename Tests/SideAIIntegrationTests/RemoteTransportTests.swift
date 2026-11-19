import XCTest
import SideAICore
import SideAIRemote
@testable import SideAI

final class RemoteTransportTests: XCTestCase {
  @MainActor func testPhoneChangesDesktopModelThroughEncryptedRelayAndReconnects() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let externalRelay = ProcessInfo.processInfo.environment["SIDEAI_TEST_RELAY_URL"]
    guard externalRelay != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("remote-relay/node_modules/ws").path) else { throw XCTSkip("Run npm ci in remote-relay for transport integration") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let portFile = dir.appendingPathComponent("port")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", root.appendingPathComponent("remote-relay/test-fixture.mjs").path, portFile.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    defer { if process.isRunning { process.terminate() } }
    let relay: String
    if let externalRelay { relay = externalRelay }
    else {
      try process.run()
      for _ in 0..<100 { if FileManager.default.fileExists(atPath: portFile.path) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
      let port = try String(contentsOf: portFile)
      relay = "ws://127.0.0.1:\(port)/v1/connect"
    }
    let store = SessionStore(directory: dir.appendingPathComponent("state")); defer { store.shutdown() }
    let profile = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [profile]; store.newConversation(route: .api(profile))
    let id = try XCTUnwrap(store.selectedID)
    let host = RemoteHost(store: store, loadSaved: false), phone = RemoteChannel()
    defer { host.stop(); phone.stop() }
    let pairing = try RemotePairing(relay: relay, name: "Fixture computer"), device = UUID().uuidString
    host.configuration = RemoteHostConfiguration(pairing: pairing, deviceID: device, deviceName: "Fixture phone")
    host.start(persistConfiguration: false)
    var nonce = UUID().uuidString, last: RemoteValue = .null, acknowledged = false, phoneStatus = "", snapshots = 0, heartbeats = 0
    phone.onStatus = { status, _ in phoneStatus = status }
    // Match the iPhone: a peer notification starts a fresh handshake and ignores any older snapshot.
    let greet = { nonce = UUID().uuidString; last = .null; phone.send(.object(["kind": .string("hello"), "device": .string(device), "nonce": .string(nonce), "time": .number(Date().timeIntervalSince1970)])) }
    phone.onReady = greet; phone.onPeer = greet
    phone.onMessage = { m in if m["nonce"].text == nonce { if m["kind"].text == "state" { last = m; snapshots += 1 }; if m["kind"].text == "heartbeat" { heartbeats += 1 }; if m["kind"].text == "ack" { acknowledged = m["error"] == .null } } }
    phone.start(pairing, role: "phone")
    for _ in 0..<1000 { if last != .null { break }; try await Task.sleep(nanoseconds: 30_000_000) }
    XCTAssertEqual(last["current"]["id"].text, id.uuidString, "Host: \(host.status); phone: \(phoneStatus)")
    guard last != .null else { return }
    let challenge = last["challenge"]
    phone.send(.object(["kind": .string("command"), "id": .string(UUID().uuidString), "op": .string("configure"), "nonce": .string(nonce), "challenge": challenge, "time": .number(Date().timeIntervalSince1970), "conversation": .string(id.uuidString), "revision": last["current"]["revision"], "model": .string("remote-fixture-model"), "effort": .string(""), "mode": .string("readOnly"), "cwd": .string(store.scratch.path)]))
    for _ in 0..<500 { if acknowledged { break }; try await Task.sleep(nanoseconds: 30_000_000) }
    XCTAssertTrue(acknowledged); XCTAssertEqual(store.selected?.modelID, "remote-fixture-model")
    phone.stop(); nonce = UUID().uuidString; last = .null; phone.start(pairing, role: "phone")
    for _ in 0..<1000 { if last != .null { break }; try await Task.sleep(nanoseconds: 30_000_000) }
    XCTAssertEqual(last["current"]["model"].text, "remote-fixture-model")
    XCTAssertNotEqual(last["challenge"], challenge, "Reconnect must invalidate captured commands")
    let snapshotCount = snapshots, heartbeatCount = heartbeats
    for _ in 0..<500 { if heartbeats > heartbeatCount { break }; try await Task.sleep(nanoseconds: 30_000_000) }
    XCTAssertGreaterThan(heartbeats, heartbeatCount, "Idle connection must remain live, including after relay hibernation")
    XCTAssertEqual(snapshots, snapshotCount, "Unchanged history must not be retransmitted as a keepalive")
  }
}
