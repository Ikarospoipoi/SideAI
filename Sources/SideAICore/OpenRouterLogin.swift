import Foundation
import CryptoKit

public struct OpenRouterLoginAttempt {
  public let state = ChatGPTLoginAttempt.random()
  public let verifier = ChatGPTLoginAttempt.random()
  public let port: UInt16
  public init(port: UInt16) { self.port = port }
  public var authorizationURL: URL {
    var url = URLComponents(string: "https://openrouter.ai/auth")!
    url.queryItems = ["callback_url": "http://127.0.0.1:\(port)/auth/callback", "state": state,
      "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL, "code_challenge_method": "S256", "key_label": "SideAI"].map { URLQueryItem(name: $0.key, value: $0.value) }
    return url.url!
  }
  public func exchangeBody(_ callback: URL) throws -> JSON {
    guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.host == "127.0.0.1", parts.scheme == "http", parts.port == Int(port), parts.path == "/auth/callback" else { throw ProtocolError.message("登录回调地址不匹配") }
    var fields = [String: String]()
    for item in parts.queryItems ?? [] { guard fields[item.name] == nil else { throw ProtocolError.message("登录回调参数重复") }; fields[item.name] = item.value ?? "" }
    guard fields["state"] == state, let code = fields["code"], !code.isEmpty, fields["error"] == nil else { throw ProtocolError.message("登录未完成或授权已取消") }
    return .object(["code": .string(code), "code_verifier": .string(verifier), "code_challenge_method": .string("S256")])
  }
}
