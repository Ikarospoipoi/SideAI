import XCTest
import Security
@testable import SideAICore

final class ChatGPTLoginTests: XCTestCase {
  func testAuthorizationPKCEAndCallbackValidation() throws {
    let attempt = ChatGPTLoginAttempt(hostID: "urn:uuid:host", port: 12345)
    let query = Dictionary(uniqueKeysWithValues: URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    XCTAssertEqual(query["client_id"], "dynamic_agent_client"); XCTAssertEqual(query["code_challenge_method"], "S256")
    XCTAssertNotEqual(query["code_challenge"], attempt.verifier)
    let good = URL(string: attempt.redirectURI + "?code=one&client_id=issued&state=" + attempt.state)!
    XCTAssertEqual(try attempt.exchangeFields(callback: good)["client_id"], "issued")
    XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: attempt.redirectURI + "?state=wrong&code=one&client_id=issued")!))
    XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&error=access_denied")!))
    XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: attempt.redirectURI + "?state=" + attempt.state + "&code=one")!))
    XCTAssertThrowsError(try attempt.exchangeFields(callback: URL(string: good.absoluteString + "&state=another")!))
  }
  func testIdentitySignatureNonceAudienceAndExpiryAreValidated() throws {
    let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
    let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
    let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
    var offset = 0
    func read() -> Data {
      offset += 1; var length = Int(data[offset]); offset += 1
      if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(data[offset]); offset += 1 } }
      let value = data.subdata(in: offset..<offset+length); offset += length; return value
    }
    _ = read(); offset = data.count > 255 ? 4 : 3
    // Read the sequence's two INTEGERs (RSA public-key external representation).
    let n = read(), e = read()
    let jwks = JSON.object(["keys": .array([.object(["kid": .string("fixture"), "kty": .string("RSA"), "n": .string(n.base64URL), "e": .string(e.base64URL)])])])
    func token(_ claims: [String: JSON]) throws -> String {
      let header = try JSONEncoder().encode(JSON.object(["alg": .string("RS256"), "kid": .string("fixture")])).base64URL
      let body = try JSONEncoder().encode(JSON.object(claims)).base64URL
      let input = header + "." + body
      let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
      return input + "." + signature.base64URL
    }
    var claims: [String: JSON] = ["iss": .string("https://auth.openai.com"), "aud": .string("issued"), "sub": .string("account"), "nonce": .string("nonce"), "exp": .number(Date().timeIntervalSince1970 + 300)]
    let good = try token(claims)
    XCTAssertEqual(try ChatGPTIdentity.validate(token: good, jwks: jwks, client: "issued", nonce: "nonce")["sub"].text, "account")
    XCTAssertThrowsError(try ChatGPTIdentity.validate(token: good, jwks: jwks, client: "wrong", nonce: "nonce"))
    XCTAssertThrowsError(try ChatGPTIdentity.validate(token: good, jwks: jwks, client: "issued", nonce: "wrong"))
    XCTAssertThrowsError(try ChatGPTIdentity.validate(token: good, jwks: jwks, client: "issued", nonce: "nonce", subject: "other"))
    claims["exp"] = .number(1)
    XCTAssertThrowsError(try ChatGPTIdentity.validate(token: token(claims), jwks: jwks, client: "issued", nonce: "nonce"))
  }
}
