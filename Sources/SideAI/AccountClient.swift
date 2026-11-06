import Foundation
import SideAICore

/// ACP transport for official account runtimes. Never implements filesystem or terminal RPCs.
@MainActor final class AccountClient {
  private let root: URL
  init(root: URL = RuntimeEnvironment.root) { self.root = root }
  private var transport: StdioTransport?
  private var nextID = 0
  private var pending = [String: CheckedContinuation<JSON, Error>]()
  private var timers = [String: Task<Void, Never>]()
  var onText: ((String) -> Void)?
  var onDiagnostic: ((String) -> Void)?
  private var text = ""
  private var initialModels: JSON = .null
  private var workingDirectory: URL?
  func start(runtime: AccountRuntime, path: String) async throws -> JSON {
    let cwd = try RuntimeEnvironment.prepare(runtime, root: root); workingDirectory = cwd
    let transport = StdioTransport(); self.transport = transport
    transport.onMessage = { [weak self] message in Task { @MainActor in self?.receive(message) } }
    transport.onDiagnostic = { [weak self] message in Task { @MainActor in self?.onDiagnostic?(message) } }
    transport.onDisconnect = { [weak self] _ in Task { @MainActor in self?.stop(reason: "官方客户端已断开，请重新连接。") } }
    try transport.start(executable: path, cwd: cwd, arguments: RuntimeEnvironment.arguments(runtime, root: root),
      environment: RuntimeEnvironment.isolated(path: path, key: runtime.environmentKey, name: runtime.rawValue, root: root))
    let info = try await request("initialize", .object(["protocolVersion": .number(1),
      "clientInfo": .object(["name": .string("SideAI"), "version": .string("0.8.0")]),
      "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)])]))
    initialModels = info["_meta"]["modelState"]
    return info
  }
  func request(_ method: String, _ params: JSON, timeout: UInt64 = 30) async throws -> JSON {
    try Task.checkCancellation()
    guard let transport else { throw ProtocolError.message("客户端未启动") }
    nextID += 1; let id = String(nextID)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        timers[id] = Task { [weak self] in
          try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
          guard !Task.isCancelled else { return }
          self?.pending.removeValue(forKey: id)?.resume(throwing: ProtocolError.message("连接超时，请重试。")); self?.timers[id] = nil
        }
        transport.send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
      }
    } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
  }
  private func receive(_ message: JSON) {
    if let method = message["method"].string {
      if method == "session/update" {
        let update = message["params"]["update"]
        if update["sessionUpdate"].text == "agent_message_chunk", let chunk = update["content"]["text"].string { text += chunk; onText?(text) }
        if ["tool_call", "tool_call_update"].contains(update["sessionUpdate"].text) { stop(reason: "聊天模式检测到工具请求，已停止。") }
      } else if message["id"] != .null {
        if method == "session/request_permission" {
          transport?.send(.object(["jsonrpc": .string("2.0"), "id": message["id"], "result": .object(["outcome": .object(["outcome": .string("cancelled")])])]))
        } else {
          transport?.send(.object(["jsonrpc": .string("2.0"), "id": message["id"], "error": .object(["code": .number(-32601), "message": .string("Not available in SideAI chat")])]))
        }
      }
      return
    }
    let id = message["id"].string ?? String(Int(message["id"].numberValue))
    guard let continuation = pending.removeValue(forKey: id) else { return }
    timers.removeValue(forKey: id)?.cancel()
    if message["error"] != .null {
      let code = Int(message["error"]["code"].numberValue)
      continuation.resume(throwing: ProtocolError.message("官方客户端返回错误（\(code)）：" + String(message["error"]["message"].text.prefix(400))))
    } else { continuation.resume(returning: message["result"]) }
  }
  func newSession(_ runtime: AccountRuntime) async throws -> JSON {
    if runtime == .grok { _ = try await request("authenticate", .object(["methodId": .string(runtime.authMethod), "_meta": .object(["headless": .bool(true)])])) }
    guard let cwd = workingDirectory else { throw ProtocolError.message("客户端未启动") }
    var session = try await request("session/new", .object(["cwd": .string(cwd.path), "mcpServers": .array([])]))
    if case .object(var fields) = session, Self.models(session).isEmpty, initialModels != .null { fields["models"] = initialModels; session = .object(fields) }
    return session
  }
  func setModel(_ model: String, session: JSON) async throws {
    let id = session["sessionId"]
    if let option = session["configOptions"].array.first(where: { $0["category"].text == "model" || $0["id"].text == "model" }) {
      _ = try await request("session/set_config_option", .object(["sessionId": id, "configId": option["id"], "value": .string(model)]))
    } else { _ = try await request("session/set_model", .object(["sessionId": id, "modelId": .string(model)])) }
  }
  func stop(reason: String? = nil) {
    let old = transport; transport = nil; old?.onDisconnect = nil; old?.stop()
    let callbacks = pending; pending.removeAll(); timers.values.forEach { $0.cancel() }; timers.removeAll()
    for callback in callbacks.values { callback.resume(throwing: reason.map(ProtocolError.message) ?? CancellationError()) }
  }
  nonisolated static func models(_ session: JSON) -> [ModelOption] {
    let legacy = session["models"]["availableModels"].array.map { ModelOption(id: $0["modelId"].text, name: $0["name"].string) }
    if !legacy.isEmpty { return legacy }
    func options(_ rows: [JSON]) -> [ModelOption] {
      rows.flatMap { row in
        if !row["options"].array.isEmpty { return options(row["options"].array) }
        return row["value"].string.map { [ModelOption(id: $0, name: row["name"].string)] } ?? []
      }
    }
    return options(session["configOptions"].array.first { $0["category"].text == "model" || $0["id"].text == "model" }?["options"].array ?? [])
  }
  nonisolated static func prompt(_ conversation: Conversation) throws -> JSON {
    var blocks = [JSON]()
    for item in conversation.items where ["userMessage", "agentMessage"].contains(item.kind) && item.status == "completed" {
      blocks.append(.object(["type": .string("text"), "text": .string((item.kind == "userMessage" ? "User: " : "Assistant: ") + item.text)]))
      for image in item.attachments ?? [] where item.kind == "userMessage" {
        blocks.append(.object(["type": .string("image"), "mimeType": .string(image.mimeType), "data": .string(try Data(contentsOf: URL(fileURLWithPath: image.path)).base64EncodedString())]))
      }
    }
    blocks.append(.object(["type": .string("text"), "text": .string("User: " + conversation.draft)]))
    for image in conversation.images {
      blocks.append(.object(["type": .string("image"), "mimeType": .string(image.mimeType), "data": .string(try Data(contentsOf: URL(fileURLWithPath: image.path)).base64EncodedString())]))
    }
    return .array(blocks)
  }
}

/// Bounded process runner used for official CLI login and private runtime installation.
final class LoginProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  func cancel() {
    lock.lock(); cancelled = true; let p = process; lock.unlock()
    if let p, p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } } }
  }
  func run(path: String, arguments: [String], environment: [String: String], cwd: URL,
           output: @escaping @Sendable (String) -> Void = { _ in }) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
          let p = Process(), pipe = Pipe()
          p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments; p.environment = environment; p.currentDirectoryURL = cwd
          p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = pipe
          self.lock.lock()
          if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
          do { try p.run(); self.process = p; self.lock.unlock() }
          catch { self.lock.unlock(); continuation.resume(throwing: error); return }
          let timeout = DispatchWorkItem { self.cancel() }
          DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
          var buffer = Data()
          while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            // Login URLs may be printed without a trailing newline.
            if let text = String(data: buffer, encoding: .utf8) { output(text); if buffer.count > 32768 { buffer = Data(buffer.suffix(8192)) } }
          }
          p.waitUntilExit(); timeout.cancel()
          self.lock.lock(); let cancelled = self.cancelled; self.process = nil; self.lock.unlock()
          if cancelled { continuation.resume(throwing: CancellationError()) }
          else if p.terminationStatus == 0 { continuation.resume() }
          else { continuation.resume(throwing: ProtocolError.message("官方客户端操作未完成（\(p.terminationStatus)）。请重试并检查网络。")) }
        }
      }
    } onCancel: { self.cancel() }
  }
}
