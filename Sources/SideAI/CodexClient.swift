import Foundation
import SideAICore
import SystemConfiguration

/// Owns blocking pipe reads off the UI actor. No network listener and no shell interpolation.
final class StdioTransport: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe(), output = Pipe(), errors = Pipe()
  private let writer = DispatchQueue(label: "SideAI.stdin")
  var onMessage: ((JSON) -> Void)?
  var onDisconnect: ((String) -> Void)?
  var onDiagnostic: ((String) -> Void)?
  func start(executable: String, cwd: URL, arguments: [String]? = nil, environment: [String: String]? = nil) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments ?? [
      "app-server", "--listen", "stdio://", "-c", "analytics.enabled=false", "-c",
      "features.apps=false", "-c", "features.multi_agent=false",
    ]
    process.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    env["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    // Rust CLI networking does not consistently inherit macOS System Settings proxies.
    // Respect an explicitly supplied environment proxy first; otherwise use the OS HTTP proxy.
    if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
      for (scheme, prefix) in [("HTTP", "HTTP"), ("HTTPS", "HTTPS")] {
        let key = scheme + "_PROXY"
        if env[key] == nil && env[key.lowercased()] == nil,
          (proxies[prefix + "Enable"] as? NSNumber)?.boolValue == true,
          let host = proxies[prefix + "Proxy"] as? String,
          let port = proxies[prefix + "Port"] as? NSNumber
        {
          env[key] = "http://\(host):\(port)"
        }
      }
      if env["NO_PROXY"] == nil {
        let exceptions = proxies["ExceptionsList"] as? [String] ?? []
        env["NO_PROXY"] =
          (["localhost", "127.0.0.1", "::1"]
          + exceptions.filter { $0 != "<local>" }.map {
            $0.replacingOccurrences(of: "*.", with: ".")
          }).joined(separator: ",")
      }
    }
    process.environment = environment ?? env
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    // Drain stderr without persisting potentially sensitive server diagnostics.
    errors.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      if !data.isEmpty { self?.onDiagnostic?(String(decoding: data, as: UTF8.self)) }
    }
    process.terminationHandler = { [weak self] p in
      self?.onDisconnect?("Codex 已退出（\(p.terminationStatus)）。请重新连接。")
    }
    try process.run()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      var framer = JSONLineFramer()
      do {
        while true {
          let data = self.output.fileHandleForReading.availableData
          if data.isEmpty { break }
          for message in try framer.append(data) { self.onMessage?(message) }
        }
      } catch {
        self.onDisconnect?("协议读取失败：\(error.localizedDescription)")
        self.stop()
      }
    }
  }
  func send(_ json: JSON) {
    writer.async { [weak self] in
      guard let self else { return }
      do {
        var data = try JSONEncoder().encode(json)
        data.append(10)
        try self.input.fileHandleForWriting.write(contentsOf: data)
      } catch { self.onDisconnect?("无法写入 Codex：\(error.localizedDescription)") }
    }
  }
  func stop() {
    errors.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning {
      process.terminate()
      let pid = process.processIdentifier, stopping = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if stopping.isRunning { kill(pid, SIGKILL) }
      }
    }
  }
}

@MainActor protocol AgentClient: AnyObject {
  var onEvent: ((JSON) -> Void)? { get set }
  var onDisconnect: ((String) -> Void)? { get set }
  func request(_ method: String, _ params: JSON) async throws -> JSON
  func respond(id: JSON, result: JSON)
  func stop()
}
@MainActor final class CodexAppServerClient: AgentClient {
  var onEvent: ((JSON) -> Void)?
  var onDisconnect: ((String) -> Void)?
  private var transport: StdioTransport?
  private var nextID = 0
  private var pending = [String: CheckedContinuation<JSON, Error>]()
  private var timeouts = [String: Task<Void, Never>]()
  private var generation = UUID()
  func connect(path: String, cwd: URL, environment: [String: String]? = nil) async throws -> JSON {
    stop()
    let gen = generation
    let t = StdioTransport()
    t.onMessage = { [weak self] message in
      Task { @MainActor in
        guard let self, self.generation == gen else { return }
        self.receive(message)
      }
    }
    t.onDisconnect = { [weak self] reason in
      Task { @MainActor in
        guard let self, self.generation == gen else { return }
        self.stop()
        self.onDisconnect?(reason)
      }
    }
    transport = t
    do { try t.start(executable: path, cwd: cwd, environment: environment) } catch {
      stop()
      throw error
    }
    _ = try await request(
      "initialize",
      .object([
        "clientInfo": .object([
          "name": .string("sideai"), "title": .string("SideAI"), "version": .string("0.7.0"),
        ]), "capabilities": .object(["experimentalApi": .bool(false)]),
      ]))
    t.send(.object(["method": .string("initialized")]))
    return try await request("account/read", .object(["refreshToken": .bool(false)]))
  }
  func request(_ method: String, _ params: JSON) async throws -> JSON {
    guard let transport else { throw ProtocolError.message("后端未连接") }
    nextID += 1
    let id = JSON.number(Double(nextID))
    let key = id.key
    return try await withCheckedThrowingContinuation { continuation in
      pending[key] = continuation
      timeouts[key] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled, let self, let c = self.pending.removeValue(forKey: key) else {
          return
        }
        self.timeouts.removeValue(forKey: key)
        c.resume(throwing: ProtocolError.message("\(method) 超时，执行状态未知。请重连恢复；不要直接重复发送。"))
        // An uncertain request may still have started a turn. Close the connection rather than retry it.
        self.stop()
        self.onDisconnect?("请求超时，连接已关闭。请恢复会话核对实际状态。")
      }
      transport.send(.object(["id": id, "method": .string(method), "params": params]))
    }
  }
  func respond(id: JSON, result: JSON) { transport?.send(.object(["id": id, "result": result])) }
  func rejectUnsupported(id: JSON) {
    transport?.send(
      .object([
        "id": id,
        "error": .object([
          "code": .number(-32601),
          "message": .string("SideAI does not support this request; no action authorized."),
        ]),
      ]))
  }
  private func receive(_ message: JSON) {
    if message["method"].string != nil {
      onEvent?(message)
      return
    }
    let key = message["id"].key
    guard let c = pending.removeValue(forKey: key) else { return }
    timeouts.removeValue(forKey: key)?.cancel()
    if message["error"] != .null {
      c.resume(throwing: ProtocolError.message(message["error"]["message"].string ?? "Codex 协议错误"))
    } else {
      c.resume(returning: message["result"])
    }
  }
  func stop() {
    generation = UUID()
    transport?.onDisconnect = nil
    transport?.stop()
    transport = nil
    let old = pending
    pending.removeAll()
    timeouts.values.forEach { $0.cancel() }
    timeouts.removeAll()
    for c in old.values { c.resume(throwing: ProtocolError.message("连接已关闭；请求不会自动重试")) }
  }
  static func findCLI(custom: String) -> String? {
    let paths =
      custom.isEmpty
      ? [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        NSHomeDirectory() + "/.npm-global/bin/codex",
      ] : [custom]
    return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
