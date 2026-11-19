import XCTest
import SideAICore
@testable import SideAI

final class ProductivityTransportTests: XCTestCase {
  private var server: Process?
  private var baseURL = ""
  override func setUpWithError() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/api_fixture.py")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", fixture.path]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); server = process
    var data = Data()
    while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data([10]) { break }; data.append(byte) }
    let port = String(decoding: data, as: UTF8.self)
    guard Int(port) != nil else { throw ProtocolError.message("本地测试服务未启动") }
    baseURL = "http://127.0.0.1:\(port)/memory-flow"
  }
  override func tearDown() { if let server, server.isRunning { server.terminate(); server.waitUntilExit() } }
  @MainActor func testBudgetedHistoryCompletesSearchReadAnswer() async throws {
    var profile = APIProfile(); profile.baseURL = baseURL
    let client = HTTPChatClient(); defer { client.cancel() }
    var calls: [String] = []
    let text = try await client.streamWithMemory(profile: profile, key: "fixture-key", body: .object(["model": .string("fixture-vision"), "input": .array([]), "store": .bool(false)]), inputBudget: 16000,
      execute: { name, _ in calls.append(name); return .object(["id": .string("fixture-source"), "text": .string("SELECT 42")]) }, update: { _ in })
    XCTAssertEqual(calls, ["search_history", "read_history"]); XCTAssertEqual(text, "根据历史 SQL，答案是 42。")
  }
  @MainActor func testOversizedHistoryResultStopsBeforeAnotherRequest() async throws {
    var profile = APIProfile(); profile.baseURL = baseURL
    let client = HTTPChatClient(); defer { client.cancel() }
    var calls = 0
    do {
      _ = try await client.streamWithMemory(profile: profile, key: "fixture-key", body: .object(["model": .string("fixture-vision"), "input": .array([]), "store": .bool(false)]), inputBudget: 4000,
        execute: { _, _ in calls += 1; return .object(["text": .string(String(repeating: "长", count: 10000))]) }, update: { _ in })
      XCTFail("Budget must stop the loop")
    } catch { XCTAssertTrue(error.localizedDescription.contains("超过预算")) }
    XCTAssertEqual(calls, 1)
  }
}
