import XCTest
@testable import SideAICore

final class RoutingTests: XCTestCase {
  func testProviderExclusivityPreservesOtherProvidersAndStoredProfiles() {
    let openAI = ProviderKind.openai.preset(), claude = ProviderKind.anthropic.preset()
    var active = ConnectionPolicy.activated(.codex, in: [:])
    active = ConnectionPolicy.activated(.claude, in: active)
    active = ConnectionPolicy.activated(.api(openAI), in: active)
    XCTAssertTrue(ConnectionPolicy.isActive(.codex, in: active))
    XCTAssertTrue(ConnectionPolicy.isActive(.claude, in: active))
    active = ConnectionPolicy.activated(.api(claude), in: active)
    XCTAssertTrue(ConnectionPolicy.isActive(.claude, in: active))
    XCTAssertTrue(ConnectionPolicy.isActive(.api(openAI), in: active))
    XCTAssertFalse(ConnectionPolicy.isActive(.archive, in: active))
  }
  func testDuplicateURLNormalizationAndProviderInference() {
    var a = ProviderKind.openai.preset(), b = ProviderKind.custom.preset()
    b.baseURL = "HTTPS://API.OPENAI.COM:443/v1///"; b.format = .responses
    XCTAssertTrue(a.duplicates(b))
    XCTAssertEqual(b.resolvedProvider, .openai)
    XCTAssertEqual(a.groupID, b.groupID)
    b.id = a.id; XCTAssertFalse(a.duplicates(b))
    a = ProviderKind.custom.preset(); a.baseURL = "https://first.example/v1"
    b = ProviderKind.custom.preset(); b.baseURL = "https://second.example/v1"
    XCTAssertNotEqual(a.groupID, b.groupID)
  }
  func testRouteIdentityAndLegacySettingsMigration() throws {
    var c = Conversation(cwd: "/tmp"); XCTAssertEqual(c.routeID, ConnectionRoute.codex.id)
    c.backend = .claude; XCTAssertEqual(c.routeID, ConnectionRoute.claude.id)
    c.backend = .api; c.profileID = UUID()
    let id = c.routeID; c.modelID = "another-model"
    XCTAssertEqual(c.routeID, id)
    let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
    XCTAssertNil(settings.activeRoutes)
  }
  func testClaudeSessionResumeModelEffortAndNoTools() throws {
    var c = Conversation(cwd: "/tmp"); c.claudeSessionID = UUID().uuidString
    c.modelID = "opus"; c.reasoningEffort = "high"; c.draft = "新消息"
    let args = try ClaudeProtocol.arguments(conversation: c)
    XCTAssertTrue(args.contains("--session-id")); XCTAssertFalse(args.contains("--resume"))
    XCTAssertTrue(args.contains("--safe-mode")); XCTAssertFalse(args.contains("--bare"))
    XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
    XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "high")
    XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "opus")
    c.claudeHasSession = true
    XCTAssertTrue(try ClaudeProtocol.arguments(conversation: c).contains("--resume"))
    c.items = [TimelineItem(kind: "agentMessage", text: "不重复提交历史")]
    let input = try ClaudeProtocol.input(c)
    XCTAssertEqual(input["message"]["content"].array.count, 1)
    XCTAssertEqual(input["message"]["content"].array[0]["text"].text, "新消息")
  }
  func testClaudeImageEncodingAndStreamSnapshotDeduplication() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1,2,3]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
    var c = Conversation(cwd: "/tmp"); c.attachments = [ImageAttachment(path: url.path, name: "image")]
    XCTAssertEqual(try ClaudeProtocol.input(c)["message"]["content"].array[0]["source"]["data"].text, "AQID")
    var stream = ClaudeStreamState()
    func event(_ raw: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(raw.utf8)) }
    try stream.receive(event(#"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"model":"actual-model"}"#))
    try stream.receive(event(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}}"#))
    try stream.receive(event(#"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}"#))
    try stream.receive(event(#"{"type":"result","subtype":"success","result":"你好","is_error":false}"#))
    XCTAssertEqual(stream.text, "你好"); XCTAssertEqual(stream.model, "actual-model"); XCTAssertTrue(stream.completed)
    XCTAssertThrowsError(try stream.receive(event(#"{"type":"result","subtype":"error","is_error":true,"result":"auth failed"}"#)))
    XCTAssertThrowsError(try stream.receive(event(#"{"type":"system","subtype":"init","tools":["Bash"],"mcp_servers":[]}"#)))
  }
}
