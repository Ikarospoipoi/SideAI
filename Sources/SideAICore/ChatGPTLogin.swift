import Foundation
import CryptoKit
import Security

public struct ChatGPTTokens: Codable {
  public var accessToken: String
  public var refreshToken: String
  public var idToken: String
  public var expiresAt: Date
  public var clientID: String
  public var subject: String
  public var email: String
  public var scopes: [String]
  public init(accessToken: String, refreshToken: String, idToken: String, expiresAt: Date, clientID: String, subject: String, email: String, scopes: [String]) {
    self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken; self.expiresAt = expiresAt
    self.clientID = clientID; self.subject = subject; self.email = email; self.scopes = scopes
  }
}
public struct ChatGPTLoginAttempt {
  public let state: String
  public let nonce: String
  public let verifier: String
  public let hostID: String
  public var redirectURI: String
  public var returning: ChatGPTTokens?
  public init(hostID: String, port: UInt16, returning: ChatGPTTokens? = nil) {
    state = Self.random(); nonce = Self.random(); verifier = Self.random()
    self.hostID = hostID; redirectURI = "http://127.0.0.1:\(port)/auth/callback"; self.returning = returning
  }
  public static func random() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return Data(bytes).base64URL
  }
  public var authorizationURL: URL {
    var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
    var fields = ["client_id": returning?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
      "response_type": "code", "redirect_uri": redirectURI,
      "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
      "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
    if let returning { fields["id_token_hint"] = returning.idToken }
    else { fields["agent_name_hint"] = "SideAI" }
    url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    return url.url!
  }
  public func exchangeFields(callback: URL) throws -> [String: String] {
    guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
          parts.path == "/auth/callback", parts.host == "127.0.0.1", parts.scheme == "http",
          parts.port == URLComponents(string: redirectURI)?.port else { throw ProtocolError.message("登录回调地址不匹配") }
    var fields = [String: String]()
    for item in parts.queryItems ?? [] {
      guard fields[item.name] == nil else { throw ProtocolError.message("登录回调参数重复") }
      fields[item.name] = item.value ?? ""
    }
    guard fields["state"] == state else { throw ProtocolError.message("登录状态校验失败") }
    guard fields["error"] == nil else { throw ProtocolError.message("登录未完成或未授权 ChatGPT 计划使用。原连接保持不变。") }
    let client = fields["client_id"] ?? returning?.clientID ?? ""
    guard !client.isEmpty, client != "dynamic_agent_client", returning == nil || client == returning?.clientID,
          let code = fields["code"], !code.isEmpty else { throw ProtocolError.message("登录未返回有效注册信息") }
    return ["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": verifier,
      "redirect_uri": redirectURI, "resource": "https://api.openai.com/v1"]
  }
}
extension Data {
  public var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  public init?(base64URL value: String) {
    let s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
  }
}
public enum ChatGPTIdentity {
  public static func validate(token: String, jwks: JSON, client: String, nonce: String?, subject: String? = nil, now: Date = Date()) throws -> JSON {
    let parts = token.split(separator: ".").map(String.init)
    guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let bodyData = Data(base64URL: parts[1]),
          let signature = Data(base64URL: parts[2]) else { throw ProtocolError.message("登录身份令牌格式无效") }
    let header = try JSONDecoder().decode(JSON.self, from: headerData)
    let claims = try JSONDecoder().decode(JSON.self, from: bodyData)
    guard header["alg"].text == "RS256", let key = jwks["keys"].array.first(where: { $0["kid"].text == header["kid"].text && $0["kty"].text == "RSA" }),
          let modulus = Data(base64URL: key["n"].text), let exponent = Data(base64URL: key["e"].text),
          let publicKey = SecKeyCreateWithData(der(0x30, integer(modulus) + integer(exponent)) as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
          SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil)
    else { throw ProtocolError.message("登录身份签名校验失败") }
    let audience = claims["aud"].string.map { [$0] } ?? claims["aud"].array.map(\.text)
    guard claims["iss"].text == "https://auth.openai.com", audience.contains(client),
          (audience.count <= 1 || claims["azp"].text == client), claims["exp"].numberValue > now.timeIntervalSince1970,
          (claims["nbf"] == .null || claims["nbf"].numberValue <= now.timeIntervalSince1970 + 60),
          !claims["sub"].text.isEmpty, nonce == nil || claims["nonce"].string == nonce,
          subject == nil || claims["sub"].string == subject else { throw ProtocolError.message("登录账号、有效期或身份校验失败") }
    return claims
  }
  private static func integer(_ bytes: Data) -> Data { der(0x02, bytes.first.map { $0 >= 128 } == true ? Data([0]) + bytes : bytes) }
  private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
    var count = bytes.count, size = [UInt8]()
    repeat { size.insert(UInt8(count & 255), at: 0); count >>= 8 } while count > 0
    let length: [UInt8] = bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(size.count)] + size
    return Data([tag] + length) + bytes
  }
}
