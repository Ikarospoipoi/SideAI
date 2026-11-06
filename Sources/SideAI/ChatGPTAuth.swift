import AppKit
import Foundation
import Network
import SideAICore

/// Loopback only. Unrelated requests cannot consume the pending OAuth callback.
final class OAuthLoopback: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: NWListener?
  private var continuation: CheckedContinuation<URL, Error>?
  private var readyContinuation: CheckedContinuation<UInt16, Error>?
  private var result: Result<URL, Error>?
  private var expectedState = ""
  private let queue = DispatchQueue(label: "SideAI.OAuth.loopback")
  func start() async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      do {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener; readyContinuation = continuation
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          self.lock.lock(); let ready = self.readyContinuation
          switch state {
          case .ready: self.readyContinuation = nil; self.lock.unlock(); if let port = listener.port?.rawValue { ready?.resume(returning: port) }
          case .failed(let error): self.readyContinuation = nil; self.lock.unlock(); ready?.resume(throwing: error); self.finish(.failure(error))
          default: self.lock.unlock()
          }
        }
        listener.newConnectionHandler = { [weak self] connection in
          guard let self else { connection.cancel(); return }
          connection.start(queue: self.queue); self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
      } catch { continuation.resume(throwing: error) }
    }
  }
  func callback(state: String) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock(); expectedState = state
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
      }
    } onCancel: { self.cancel() }
  }
  func prepare(state: String) { lock.lock(); expectedState = state; lock.unlock() }
  func cancel() { finish(.failure(CancellationError())) }
  private func finish(_ result: Result<URL, Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result; let callback = continuation; continuation = nil
    let ready = readyContinuation; readyContinuation = nil; lock.unlock()
    callback?.resume(with: result); ready?.resume(throwing: CancellationError()); listener?.cancel()
  }
  private func receive(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
      guard let self else { connection.cancel(); return }
      let bytes = data + (chunk ?? Data())
      guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
      guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
        if complete { connection.cancel() } else { self.receive(connection, data: bytes) }; return
      }
      let pieces = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
      self.lock.lock(); let state = self.expectedState; self.lock.unlock()
      let url = pieces.count >= 2 ? URL(string: "http://127.0.0.1:\(self.listener?.port?.rawValue ?? 0)" + String(pieces[1])) : nil
      let parts = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
      let valid = pieces.first == "GET" && parts?.path == "/auth/callback" && !state.isEmpty && parts?.queryItems?.first(where: { $0.name == "state" })?.value == state
      let body = valid ? "SideAI has received the sign-in response. Return to SideAI to check the result." : "Invalid callback."
      let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel(); if valid, let url { self.finish(.success(url)) } })
    }
  }
}

final class ChatGPTAuthHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  func close() { session.invalidateAndCancel() }
  func request(_ url: URL, form: [String: String]? = nil, json: JSON? = nil) async throws -> JSON {
    var request = URLRequest(url: url); request.timeoutInterval = 30
    if let form {
      request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      request.httpBody = form.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").data(using: .utf8)
    }
    if let json {
      request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(json)
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw ProtocolError.message("官方登录服务返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。未修改现有连接；可重试或使用 API。")
    }
    return data.isEmpty ? .object([:]) : try JSONDecoder().decode(JSON.self, from: data)
  }
  func jwks() async throws -> JSON {
    let discovery = try await request(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
    guard discovery["issuer"].text == "https://auth.openai.com", let url = URL(string: discovery["jwks_uri"].text),
          url.scheme == "https", url.host == "auth.openai.com" else { throw ProtocolError.message("OpenAI 身份验证配置无效") }
    return try await request(url)
  }
  func exchange(_ fields: [String: String], nonce: String?, previous: ChatGPTTokens?) async throws -> ChatGPTTokens {
    let raw = try await request(URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, form: fields)
    let scopes = raw["scope"].string?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
    guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke"),
          raw["token_type"].text.lowercased() == "bearer", !raw["access_token"].text.isEmpty,
          raw["expires_in"].numberValue > 0 else { throw ProtocolError.message("未获得 ChatGPT 计划使用权限；不能发送模型请求。") }
    let client = fields["client_id"]!
    var identity: JSON
    if let token = raw["id_token"].string {
      identity = try ChatGPTIdentity.validate(token: token, jwks: await jwks(), client: client, nonce: nonce, subject: previous?.subject)
    } else if let previous, nonce == nil { identity = .object(["sub": .string(previous.subject), "email": .string(previous.email)]) }
    else { throw ProtocolError.message("登录未返回身份令牌") }
    return ChatGPTTokens(accessToken: raw["access_token"].text, refreshToken: raw["refresh_token"].string ?? previous?.refreshToken ?? "",
                         idToken: raw["id_token"].string ?? previous?.idToken ?? "", expiresAt: Date().addingTimeInterval(raw["expires_in"].numberValue),
                         clientID: client, subject: identity["sub"].text, email: identity["email"].string ?? previous?.email ?? "ChatGPT 账号", scopes: scopes)
  }
}
