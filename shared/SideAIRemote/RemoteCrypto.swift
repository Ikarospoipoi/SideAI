import Foundation
import CryptoKit

public struct RemotePairing: Codable, Equatable {
  public var version = 1
  public var relay: String
  public var room: String
  public var secret: String
  public var name: String
  public var expires: Double
  public init(relay: String, name: String) throws {
    self.relay = try Self.endpoint(relay).absoluteString
    room = UUID().uuidString.lowercased(); secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    self.name = String(name.prefix(80)); expires = Date().timeIntervalSince1970 + 600
  }
  public static func endpoint(_ value: String) throws -> URL {
    guard let u = URL(string: value), let host = u.host, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
      u.scheme == "wss" || (u.scheme == "ws" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)), u.path == "/v1/connect" else { throw RemoteError.message("中继地址需为 wss://你的域名/v1/connect；本机测试可用 ws://127.0.0.1:端口/v1/connect。") }
    return u
  }
  public func validate() throws {
    _ = try Self.endpoint(relay)
    guard version == 1, UUID(uuidString: room) != nil, Data(base64Encoded: secret)?.count == 32 else { throw RemoteError.message("配对信息无效") }
  }
  public var link: String { "sideai://pair#" + ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString() }
  public static func parse(_ value: String, now: Date = Date()) throws -> Self {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count < 4096, value.hasPrefix("sideai://pair#"), let data = Data(base64Encoded: String(value.dropFirst("sideai://pair#".count))) else { throw RemoteError.message("请扫描电脑上的配对二维码，或粘贴完整配对链接。") }
    let result = try JSONDecoder().decode(Self.self, from: data); try result.validate()
    guard result.expires > now.timeIntervalSince1970, result.expires < now.timeIntervalSince1970 + 660 else { throw RemoteError.message("二维码已过期，请在电脑上重新生成。") }
    return result
  }
  public func relayToken(_ role: String) -> String {
    let key = SymmetricKey(data: Data(base64Encoded: secret)!)
    return Data(HMAC<SHA256>.authenticationCode(for: Data(("SideAI relay v1 " + role).utf8), using: key)).base64EncodedString()
  }
  public var phoneHash: String { Data(SHA256.hash(data: Data(relayToken("phone").utf8))).map { String(format: "%02x", $0) }.joined() }
}

/// Authenticated encryption; role, room, session and sequence are bound as associated data.
/// Command authorization additionally requires a fresh host challenge after every reconnect.
public final class RemoteCipher {
  private let pairing: RemotePairing
  private let role: String
  private let session = UUID().uuidString.lowercased()
  private var sequence = 0
  private var received = [String: Int]()
  public init(pairing: RemotePairing, role: String) { self.pairing = pairing; self.role = role }
  private func key(_ role: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(base64Encoded: pairing.secret)!), salt: Data(pairing.room.utf8), info: Data(("SideAI remote v1 " + role).utf8), outputByteCount: 32)
  }
  public func seal(_ value: RemoteValue) throws -> String {
    sequence += 1
    let aad = "\(pairing.room)|\(role)|\(session)|\(sequence)"
    let data = try JSONEncoder().encode(value)
    guard data.count <= 1_400_000 else { throw RemoteError.message("远程内容过大") }
    let box = try AES.GCM.seal(data, using: key(role), authenticating: Data(aad.utf8)).combined!
    let frame: RemoteValue = .object(["v": .number(1), "room": .string(pairing.room), "role": .string(role), "session": .string(session), "seq": .number(Double(sequence)), "box": .string(box.base64EncodedString())])
    return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
  }
  public func open(_ text: String) throws -> RemoteValue {
    guard text.utf8.count <= 2_000_000 else { throw RemoteError.message("远程数据过大") }
    let frame = try JSONDecoder().decode(RemoteValue.self, from: Data(text.utf8))
    let peer = role == "host" ? "phone" : "host", id = frame["session"].text, seq = frame["seq"].number
    guard frame["v"].number == 1, frame["role"].text == peer, frame["room"].text == pairing.room, UUID(uuidString: id) != nil,
      seq >= 1, seq < 9_007_199_254_740_991, seq.rounded() == seq, Int(seq) > (received[id] ?? 0), let data = Data(base64Encoded: frame["box"].text) else { throw RemoteError.message("远程消息校验失败或已处理") }
    let aad = "\(pairing.room)|\(peer)|\(id)|\(Int(seq))"
    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(peer), authenticating: Data(aad.utf8))
    let value = try JSONDecoder().decode(RemoteValue.self, from: plain)
    guard received[id] != nil || received.count < 128 else { throw RemoteError.message("请重新连接设备") }
    received[id] = Int(seq)
    return value
  }
}
