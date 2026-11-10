import XCTest
@testable import SideAIRemote

final class RemoteCryptoTests: XCTestCase {
  func testPairingExpirationAndTransport() throws {
    let p = try RemotePairing(relay: "wss://relay.example.com/v1/connect", name: "Desktop")
    XCTAssertEqual(try RemotePairing.parse(p.link), p)
    XCTAssertThrowsError(try RemotePairing.parse(p.link, now: Date().addingTimeInterval(601)))
    XCTAssertThrowsError(try RemotePairing(relay: "ws://example.com/v1/connect", name: "x"))
    XCTAssertThrowsError(try RemotePairing(relay: "wss://user:pass@example.com/v1/connect", name: "x"))
    XCTAssertNotEqual(p.relayToken("phone"), p.relayToken("host"))
  }
  func testAuthenticatedEncryptionAndReplay() throws {
    let p = try RemotePairing(relay: "ws://127.0.0.1:8787/v1/connect", name: "Desktop")
    let host = RemoteCipher(pairing: p, role: "host"), phone = RemoteCipher(pairing: p, role: "phone")
    let value: RemoteValue = .object(["text": .string("私密内容，不应出现在中继")])
    let frame = try phone.seal(value)
    XCTAssertFalse(frame.contains("私密内容"))
    XCTAssertEqual(try host.open(frame), value)
    XCTAssertThrowsError(try host.open(frame))
    XCTAssertThrowsError(try phone.open(frame))
    let another = try RemotePairing(relay: p.relay, name: "Other")
    XCTAssertThrowsError(try RemoteCipher(pairing: another, role: "host").open(frame))
    let next = try phone.seal(value)
    let bad = next.replacingOccurrences(of: "\"phone\"", with: "\"host\"")
    XCTAssertThrowsError(try host.open(bad))
    XCTAssertEqual(try host.open(next), value)
  }
}
