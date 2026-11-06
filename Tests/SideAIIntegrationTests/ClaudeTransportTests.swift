import XCTest
import AppKit
import SideAICore
@testable import SideAI

final class ClaudeTransportTests: XCTestCase {
  func testCancellationBeforeLaunchAndDuringStream() async throws {
    let stopped = ClaudeCodeClient(); stopped.cancel()
    do {
      _ = try await stopped.run(path: "/usr/bin/false", arguments: [], input: Data(), cwd: URL(fileURLWithPath: "/tmp")) { _ in }
      XCTFail("Cancelled client must not launch")
    } catch is CancellationError { }
    let client = ClaudeCodeClient()
    let task = Task { try await client.run(path: "/bin/sleep", arguments: ["30"], input: Data(), cwd: URL(fileURLWithPath: "/tmp")) { _ in } }
    try await Task.sleep(nanoseconds: 150_000_000)
    task.cancel()
    do { _ = try await task.value; XCTFail("Running process must cancel") } catch is CancellationError { }
  }
  func testMalformedProcessOutputFails() async throws {
    let client = ClaudeCodeClient()
    do {
      _ = try await client.run(path: "/usr/bin/printf", arguments: ["not-json\n"], input: Data(), cwd: URL(fileURLWithPath: "/tmp")) { _ in }
      XCTFail("Malformed protocol output must fail")
    } catch { }
  }
  func testLiveClaudeAgentFilePermissions() async throws {
    guard ProcessInfo.processInfo.environment["SIDEAI_CLAUDE_AGENT_LIVE"] == "1" else { throw XCTSkip("Opt-in live Claude Agent verification") }
    let path = try XCTUnwrap(ClaudeCodeClient.findCLI())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sideai-agent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("note.txt")
    try "ORIGINAL".write(to: file, atomically: true, encoding: .utf8)
    for allow in [false, true] {
      var c = Conversation(cwd: dir.path); c.backend = .claude; c.claudeAgentEnabled = true; c.mode = .project
      c.claudeSessionID = UUID().uuidString; c.modelID = "sonnet"; c.reasoningEffort = "low"
      c.draft = "Test fixture only: use the Write tool to replace note.txt with exactly UPDATED. If permission is denied, stop immediately and report denial; do not try another tool."
      let conversation = c
      let client = ClaudeCodeClient(), accumulator = ClaudeAccumulator(allowedTools: ClaudePermissions.tools(for: conversation))
      let approvals = ApprovalCounter()
      var input = try JSONEncoder().encode(ClaudeProtocol.input(c)); input.append(10)
      let timeout = Task { try? await Task.sleep(nanoseconds: 90_000_000_000); if !Task.isCancelled { client.cancel() } }
      defer { timeout.cancel() }
      let code = try await client.run(path: path, arguments: ClaudeProtocol.arguments(conversation: c), input: input, cwd: dir, interactive: true) { event in
        accumulator.receive(event)
        if event["type"].text == "control_request" {
          approvals.increment()
          let valid = ClaudePermissions.approval(event: event, conversation: conversation) != nil
          client.sendControl(ClaudePermissions.reply(id: event["request_id"].text, input: event["request"]["input"], allow: allow && valid))
        }
        if accumulator.snapshot().error != nil { client.cancel() }
      }
      let result = accumulator.snapshot()
      XCTAssertEqual(code, 0); XCTAssertNil(result.error); XCTAssertTrue(result.state.completed)
      XCTAssertGreaterThan(approvals.value, 0, "A write must require a visible permission request")
      XCTAssertEqual(try String(contentsOf: file), allow ? "UPDATED" : "ORIGINAL")
      print("LIVE_CLAUDE_AGENT approved=\(allow) callbacks=\(approvals.value) completed=\(result.state.completed)")
    }
  }
  /// Explicitly opt in: uses the locally signed-in account for two small real requests.
  func testLiveClaudeTextImageAndSessionResume() async throws {
    guard ProcessInfo.processInfo.environment["SIDEAI_CLAUDE_LIVE"] == "1" else { throw XCTSkip("Opt-in live Claude verification") }
    let path = try XCTUnwrap(ClaudeCodeClient.findCLI())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sideai-live-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<128 { for x in 0..<128 {
      let offset = y * bitmap.bytesPerRow + x * 4
      bitmap.bitmapData![offset] = 255; bitmap.bitmapData![offset + 1] = 0
      bitmap.bitmapData![offset + 2] = 0; bitmap.bitmapData![offset + 3] = 255
    } }
    let image = dir.appendingPathComponent("red.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: image)
    var c = Conversation(cwd: dir.path); c.claudeSessionID = UUID().uuidString.lowercased(); c.modelID = "sonnet"; c.reasoningEffort = "low"
    c.draft = "Remember the exact test word SIDEAI_ORCHID. Reply with that word only."
    func send(_ conversation: Conversation) async throws -> ClaudeStreamState {
      let client = ClaudeCodeClient(), accumulator = ClaudeAccumulator()
      var input = try JSONEncoder().encode(ClaudeProtocol.input(conversation)); input.append(10)
      let timeout = Task { try? await Task.sleep(nanoseconds: 90_000_000_000); if !Task.isCancelled { client.cancel() } }
      defer { timeout.cancel() }
      let code = try await client.run(path: path, arguments: ClaudeProtocol.arguments(conversation: conversation), input: input, cwd: dir, effort: conversation.reasoningEffort) { accumulator.receive($0) }
      let result = accumulator.snapshot()
      XCTAssertNil(result.error); XCTAssertEqual(code, 0); XCTAssertTrue(result.state.completed)
      return result.state
    }
    let first = try await send(c)
    XCTAssertTrue(first.text.contains("SIDEAI_ORCHID")); XCTAssertTrue(first.started)
    c.claudeHasSession = true; c.draft = "Reply with the test word I asked you to remember followed by the image's main color in English. No other words."
    c.attachments = [ImageAttachment(path: image.path, name: "red.png")]
    let second = try await send(c)
    XCTAssertTrue(second.text.contains("SIDEAI_ORCHID"), second.text); XCTAssertTrue(second.text.lowercased().contains("red"), second.text)
    print("LIVE_CLAUDE_RESPONSE model=\(second.model ?? "unknown") text=\(second.text)")
  }
}

private final class ApprovalCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func increment() { lock.lock(); count += 1; lock.unlock() }
}
