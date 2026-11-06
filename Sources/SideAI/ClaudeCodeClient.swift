import Foundation
import SideAICore
import SystemConfiguration

/// Uses the installed official CLI. Never reads or copies its credential files.
final class ClaudeCodeClient: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private var writer: FileHandle?
  private let writeQueue = DispatchQueue(label: "SideAI.Claude.stdin")
  func sendControl(_ event: JSON) {
    guard var data = try? JSONEncoder().encode(event) else { return }; data.append(10)
    writeQueue.async { [self] in lock.lock(); let handle = writer; lock.unlock(); try? handle?.write(contentsOf: data) }
  }
  func cancel() {
    lock.lock(); cancelled = true; let p = process; lock.unlock()
    if let p, p.isRunning {
      p.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }
  }
  func run(path: String, arguments: [String], input: Data, cwd: URL, effort: String? = nil, interactive: Bool = false, environment: [String: String]? = nil,
           event: @escaping @Sendable (JSON) -> Void) async throws -> Int32 {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
          p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments; p.currentDirectoryURL = cwd
          var env = environment ?? Self.environment(path: path)
          if let effort { env["CLAUDE_CODE_EFFORT_LEVEL"] = effort } else { env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL") }
          p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
          stderr.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
          self.lock.lock()
          if self.cancelled { self.lock.unlock(); stderr.fileHandleForReading.readabilityHandler = nil; continuation.resume(throwing: CancellationError()); return }
          do { try p.run(); self.process = p; self.writer = stdin.fileHandleForWriting; self.lock.unlock() }
          catch { self.lock.unlock(); stderr.fileHandleForReading.readabilityHandler = nil; continuation.resume(throwing: error); return }
          // Large image inputs must not block the stdout reader or the main actor.
          if interactive {
            self.sendControl(.object(["type": .string("control_request"), "request_id": .string("sideai-initialize"), "request": .object(["subtype": .string("initialize"), "hooks": .null])]))
          } else {
            self.writeQueue.async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
          }
          do {
            var framer = JSONLineFramer()
            while true {
              let data = stdout.fileHandleForReading.availableData
              if data.isEmpty { break }
              for message in try framer.append(data) {
                if interactive, message["type"].text == "control_response", message["response"]["request_id"].text == "sideai-initialize" {
                  guard message["response"]["subtype"].text == "success" else { throw ProtocolError.message("Claude Agent 初始化失败") }
                  self.writeQueue.async { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                }
                event(message)
                if interactive && message["type"].text == "result" { self.writeQueue.async { try? stdin.fileHandleForWriting.close() } }
              }
            }
            p.waitUntilExit(); stderr.fileHandleForReading.readabilityHandler = nil
            self.lock.lock(); let cancelled = self.cancelled; self.process = nil; self.writer = nil; self.lock.unlock()
            if cancelled { continuation.resume(throwing: CancellationError()) } else { continuation.resume(returning: p.terminationStatus) }
          } catch {
            self.cancel(); stderr.fileHandleForReading.readabilityHandler = nil
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: { self.cancel() }
  }
  static func findCLI(custom: String = "") -> String? {
    if !custom.isEmpty { return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil }
    var paths = [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    let nvm = URL(fileURLWithPath: NSHomeDirectory() + "/.nvm/versions/node")
    let versions = (try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []
    paths += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/claude").path }
    return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  static func environment(path: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    env.removeValue(forKey: "CLAUDECODE")
    if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
      for scheme in ["HTTP", "HTTPS"] where env[scheme + "_PROXY"] == nil && env[scheme.lowercased() + "_proxy"] == nil {
        if (proxies[scheme + "Enable"] as? NSNumber)?.boolValue == true, let host = proxies[scheme + "Proxy"] as? String, let port = proxies[scheme + "Port"] as? NSNumber {
          env[scheme + "_PROXY"] = "http://\(host):\(port)"
        }
      }
    }
    return env
  }
  static func authStatus(path: String, environment customEnvironment: [String: String]? = nil) async throws -> JSON {
    try await Task.detached(priority: .utility) {
      let p = Process(), pipe = Pipe()
      p.executableURL = URL(fileURLWithPath: path); p.arguments = ["auth", "status"]
      p.environment = customEnvironment ?? environment(path: path); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
      try p.run()
      let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
      let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); timeout.cancel()
      guard !data.isEmpty else { throw ProtocolError.message("Claude 登录状态读取失败，请检查 CLI 版本。") }
      return try JSONDecoder().decode(JSON.self, from: data)
    }.value
  }
}
