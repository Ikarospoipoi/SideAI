import Foundation
import SideAICore

/// An adapter for text/image chat. Only explicitly supplied read-only history tools can execute; no shell or file mutations.
final class HTTPChatClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var operations = [UUID: @Sendable () -> Void]()
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
  // Cancellation cancels Swift tasks, never invalidates a session before bytes(for:) creates its task.
  // Each operation owns its session until the async call has returned, including cancellation.
  func cancel() {
    lock.lock(); cancelled = true; let callbacks = Array(operations.values); lock.unlock()
    callbacks.forEach { $0() }
  }
  private func begin<T>(_ work: @escaping @Sendable (URLSession) async throws -> T) throws -> (UUID, Task<T, Error>) {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    let id = UUID()
    let task = Task {
      try Task.checkCancellation()
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 900
      config.urlCache = nil; config.httpCookieStorage = nil
      let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }
      let value = try await work(session)
      try Task.checkCancellation()
      return value
    }
    operations[id] = { task.cancel() }
    return (id, task)
  }
  private func finish(_ id: UUID) { lock.lock(); operations[id] = nil; lock.unlock() }
  private func perform<T>(_ work: @escaping @Sendable (URLSession) async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let (id, task) = try begin(work)
    defer { finish(id) }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
  private func request(_ profile: APIProfile, key: String, path: String) throws -> URLRequest {
    var r = URLRequest(url: try profile.endpoint(path)); r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    if profile.format == .anthropic { r.setValue(nil, forHTTPHeaderField: "Authorization"); r.setValue(key, forHTTPHeaderField: "x-api-key"); r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    r.setValue("application/json", forHTTPHeaderField: "Content-Type"); return r
  }
  func models(profile: APIProfile, key: String) async throws -> [ModelOption] {
    let (data, response) = try await perform { session in
      try await session.data(for: self.request(profile, key: key, path: "models"))
    }
    try validate(response, data: data, key: key)
    let raw = try JSONDecoder().decode(JSON.self, from: data)
    let rows = profile.auth == .chatgptPlan ? raw["models"].array.filter { $0["visibility"].text == "list" } : raw["data"].array
    let result = rows.compactMap { row -> ModelOption? in
      guard let id = profile.auth == .chatgptPlan ? row["slug"].string : row["id"].string else { return nil }
      return ModelOption(api: row, id: id).withDocumentedCapabilities(for: profile)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    guard !result.isEmpty else { throw ProtocolError.message("连接成功，但 /models 没有返回模型；可手动填写该服务支持的模型 ID。") }
    return result
  }
  func stream(profile: APIProfile, key: String, body: JSON, update: @escaping @MainActor (String) -> Void) async throws -> String {
    try await perform { session in
      try await self.stream(session: session, profile: profile, key: key, body: body, update: update).text
    }
  }
  private func stream(session: URLSession, profile: APIProfile, key: String, body: JSON, allowHistoryTools: Bool = false, update: @escaping @MainActor (String) -> Void) async throws -> (text: String, output: [JSON]) {
    var req = try request(profile, key: key, path: profile.format == .responses ? "responses" : profile.format == .anthropic ? "messages" : "chat/completions")
    req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(body); req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes { data.append(byte); if data.count >= 16_384 { break } }
      try validate(response, data: data, key: key); throw ProtocolError.message("API 连接失败")
    }
    var decoder = SSEDecoder(), text = "", finished = false, lastPublish = Date.distantPast
    var outputItems = [JSON]()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard let payload = try decoder.consume(byte: byte) else { continue }
      if payload == "[DONE]" { if profile.format != .responses { finished = true }; break }
      guard let data = payload.data(using: .utf8) else { continue }
      let event = try JSONDecoder().decode(JSON.self, from: data)
      if event["error"] != .null || ["error", "response.failed"].contains(event["type"].text) {
        let reason = event["error"]["message"].string ?? event["response"]["error"]["message"].string ?? event["message"].string ?? "API 生成失败"
        throw HTTPChatFailure(diagnostic: diagnostic(http, payload: event), message: reason.replacingOccurrences(of: key, with: "[redacted]"))
      }
      if profile.format == .responses {
        switch event["type"].text {
        case "response.output_text.delta", "response.refusal.delta": text += event["delta"].text
        case "response.completed":
          outputItems = event["response"]["output"].array
          let output = event["response"]["output"].array.flatMap { $0["content"].array }.map { $0["text"].string ?? $0["refusal"].text }.joined()
          if !output.isEmpty { text = output }; finished = true
        case "response.incomplete": throw ProtocolError.message("API 回复不完整：\(event["response"]["incomplete_details"].pretty)")
        default: break
        }
      } else if profile.format == .anthropic {
        switch event["type"].text {
        case "content_block_delta":
          if event["delta"]["type"].text == "text_delta" { text += event["delta"]["text"].text }
        case "message_delta":
          if let reason = event["delta"]["stop_reason"].string, !["end_turn", "stop_sequence"].contains(reason) { throw ProtocolError.message("Claude API 以 \(reason) 结束；本模式不执行工具，回复可能不完整。") }
        case "message_stop": finished = true
        default: break
        }
      } else {
        for choice in event["choices"].array {
          text += choice["delta"]["content"].text
          text += choice["delta"]["refusal"].text
          if let reason = choice["finish_reason"].string {
            guard reason == "stop" else { throw ProtocolError.message("API 以 \(reason) 结束，回复可能不完整。本模式不执行工具。") }
            finished = true
          }
        }
      }
      if Date().timeIntervalSince(lastPublish) >= 0.05 || finished { await update(text); lastPublish = Date() }
      if finished { break }
    }
    await update(text)
    guard finished else { throw ProtocolError.message("API 流在结束事件之前断开。已保留部分回复，不会自动重发。") }
    guard !text.isEmpty || (allowHistoryTools && outputItems.contains { $0["type"].text == "function_call" }) else { throw ProtocolError.message("API 已结束但没有返回可显示的文本") }
    return (text, outputItems)
  }
  func streamWithMemory(profile: APIProfile, key: String, body: JSON,
    execute: @escaping @MainActor (String, String) async throws -> JSON,
    update: @escaping @MainActor (String) -> Void) async throws -> String {
    guard profile.format == .responses, case .object(var requestBody) = body else { throw ProtocolError.message("此协议尚不支持历史工具") }
    requestBody["tools"] = MemoryTools.definitions
    requestBody["instructions"] = .string(MemoryTools.instructions)
    requestBody["include"] = .array([.string("reasoning.encrypted_content")])
    return try await perform { session in
      var next = requestBody, input = body["input"].array, accumulated = "", seen = Set<String>(), callsUsed = 0
      for round in 0...6 {
        try Task.checkCancellation()
        next["input"] = .array(input)
        if round == 6 { next["tool_choice"] = .string("none") }
        guard try JSONEncoder().encode(JSON.object(next)).count <= 24_000_000 else { throw ProtocolError.message("历史检索上下文过大，请缩小查询范围") }
        let prefix = accumulated
        let result = try await self.stream(session: session, profile: profile, key: key, body: .object(next), allowHistoryTools: true) { text in
          update(prefix + text)
        }
        let calls = result.output.filter { $0["type"].text == "function_call" }
        if calls.isEmpty { return accumulated + result.text }
        guard round < 6, callsUsed + calls.count <= 16 else { throw ProtocolError.message("本轮历史检索已达上限，请缩小查询范围后继续") }
        callsUsed += calls.count
        if !result.text.isEmpty { accumulated += result.text + "\n\n" }
        // Replay all output, including reasoning and message phase, without server-side storage.
        input += result.output
        for call in calls {
          try Task.checkCancellation()
          let id = call["call_id"].text, name = call["name"].text
          guard !id.isEmpty, seen.insert(id).inserted else { throw ProtocolError.message("历史工具调用标识无效或重复") }
          let output: JSON
          if call["namespace"].text != "sideai_memory" || !["search_history", "read_history"].contains(name) {
            output = .object(["error": .string("仅允许 sideai_memory 的只读历史工具")])
          } else {
            output = try await execute(name, call["arguments"].text)
          }
          try Task.checkCancellation()
          input.append(.object(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(output.pretty)]))
        }
      }
      throw ProtocolError.message("历史检索未完成")
    }
  }
  func streamWithMemory(profile: APIProfile, key: String, body: JSON, inputBudget: Int,
    execute: @escaping @MainActor (String, String) async throws -> JSON,
    update: @escaping @MainActor (String) -> Void) async throws -> String {
    guard profile.format == .responses, case .object(var requestBody) = body else { throw ProtocolError.message("此协议尚不支持历史工具") }
    requestBody["tools"] = MemoryTools.definitions
    requestBody["instructions"] = .string(MemoryTools.instructions)
    requestBody["include"] = .array([.string("reasoning.encrypted_content")])
    let configuredBody = requestBody
    return try await perform { session in
      var next = configuredBody, input = body["input"].array, accumulated = "", seen = Set<String>(), callsUsed = 0
      for round in 0...6 {
        try Task.checkCancellation()
        let cost = Self.estimatedInputCost(.array(input)) + 1024
        guard cost <= max(1000, inputBudget) else { throw ProtocolError.message("历史工具上下文超过预算。请缩小记忆范围、调整预算或关闭记忆后重试；没有自动重发。") }
        next["input"] = .array(input)
        if inputBudget - cost < 3000 { next["tool_choice"] = .string("none") }
        if round == 6 { next["tool_choice"] = .string("none") }
        guard try JSONEncoder().encode(JSON.object(next)).count <= 24_000_000 else { throw ProtocolError.message("历史检索上下文过大，请缩小查询范围") }
        let prefix = accumulated
        let result = try await self.stream(session: session, profile: profile, key: key, body: .object(next), allowHistoryTools: true) { text in
          update(prefix + text)
        }
        let calls = result.output.filter { $0["type"].text == "function_call" }
        if calls.isEmpty { return accumulated + result.text }
        guard round < 6, callsUsed + calls.count <= 16 else { throw ProtocolError.message("本轮历史检索已达上限，请缩小查询范围后继续") }
        callsUsed += calls.count
        if !result.text.isEmpty { accumulated += result.text + "\n\n" }
        // Replay all output, including reasoning and message phase, without server-side storage.
        input += result.output
        for call in calls {
          try Task.checkCancellation()
          let id = call["call_id"].text, name = call["name"].text
          guard !id.isEmpty, seen.insert(id).inserted else { throw ProtocolError.message("历史工具调用标识无效或重复") }
          let output: JSON
          if call["namespace"].text != "sideai_memory" || !["search_history", "read_history"].contains(name) {
            output = .object(["error": .string("仅允许 sideai_memory 的只读历史工具")])
          } else {
            output = try await execute(name, call["arguments"].text)
          }
          try Task.checkCancellation()
          input.append(.object(["type": .string("function_call_output"), "call_id": .string(id), "output": .string(output.pretty)]))
        }
      }
      throw ProtocolError.message("历史检索未完成")
    }
  }
  private static func estimatedInputCost(_ value: JSON) -> Int {
    switch value {
    case .string(let text): return ContextPlanner.estimate(text)
    case .array(let rows): return rows.reduce(0) { $0 + estimatedInputCost($1) }
    case .object(let fields):
      if ["input_image", "image_url", "image"].contains(fields["type"]?.text ?? "") { return 1600 }
      return fields.filter { $0.key != "encrypted_content" }.reduce(0) { $0 + estimatedInputCost($1.value) }
    default: return 0
    }
  }
  private func diagnostic(_ response: HTTPURLResponse, payload: JSON) -> HTTPFailureDiagnostic {
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
    }
    return HTTPFailureDiagnostic(url: response.url ?? URL(string: "https://unknown.invalid")!, status: response.statusCode, headers: headers, payload: payload)
  }
  private func validate(_ response: URLResponse, data: Data, key: String) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let json = try? JSONDecoder().decode(JSON.self, from: data)
      let message = json?["error"]["message"].string ?? "请检查 API 地址、密钥、额度及服务是否支持该协议"
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let http = response as? HTTPURLResponse {
        throw HTTPChatFailure(diagnostic: diagnostic(http, payload: json ?? .null), message: "HTTP \(code)：" + message.replacingOccurrences(of: key, with: "[redacted]"))
      }
      throw ProtocolError.message("未收到 HTTP 响应")
    }
  }
}
