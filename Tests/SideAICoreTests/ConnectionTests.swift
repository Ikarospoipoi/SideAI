import XCTest
@testable import SideAICore

final class ConnectionTests: XCTestCase {
  func testLegacySnapshotRetainsDraftAndThread() throws {
    let c = Conversation(cwd: "/tmp/project")
    var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Snapshot(conversations: [c], selectedID: c.id))) as! [String: Any]
    var old = (raw["conversations"] as! [[String: Any]])[0]
    old["draft"] = "未发送的草稿"; old["threadID"] = "existing-thread"
    raw["conversations"] = [old]
    let restored = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: raw))
    XCTAssertEqual(restored.conversations[0].draft, "未发送的草稿")
    XCTAssertEqual(restored.conversations[0].engine, .codex)
    XCTAssertEqual(restored.conversations[0].threadID, "existing-thread")
  }
  func testModelAndWorkspaceChangeInNextTurnWithImageOnly() {
    var c = Conversation(cwd: "/tmp/new-project"); c.mode = .project
    c.modelID = "gpt-6-astra"; c.reasoningEffort = "high"
    c.attachments = [ImageAttachment(path: "/tmp/photo.png", name: "照片")]
    XCTAssertTrue(c.canSendContent)
    let p = c.codexTurnParams(threadID: "existing")
    XCTAssertEqual(p["model"].text, "gpt-6-astra")
    XCTAssertEqual(p["effort"].text, "high")
    XCTAssertEqual(p["cwd"].text, "/tmp/new-project")
    XCTAssertEqual(p["sandboxPolicy"]["writableRoots"].array, [.string("/tmp/new-project")])
    XCTAssertEqual(p["input"].array[0]["type"].text, "localImage")
    XCTAssertEqual(p["input"].array[0]["path"].text, "/tmp/photo.png")
  }
  func testAPIFormatsCarryHistoryAndImagesWithoutToolsOrCloudState() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3]).write(to: path); defer { try? FileManager.default.removeItem(at: path) }
    var c = Conversation(cwd: "/tmp")
    var item = TimelineItem(kind: "userMessage", text: "图片是什么？")
    item.attachments = [ImageAttachment(path: path.path, name: "测试")]
    c.items = [item, TimelineItem(kind: "agentMessage", text: "你好"), TimelineItem(kind: "commandExecution", text: "private command"), TimelineItem(kind: "agentMessage", text: "partial", status: "failed")]
    for format in APIFormat.allCases {
      let body = try APIRequestBuilder.body(conversation: c, format: format, model: "chosen-model")
      let rows = body[format == .responses ? "input" : "messages"].array
      XCTAssertEqual(rows.count, 2)
      XCTAssertEqual(body["model"].text, "chosen-model")
      XCTAssertEqual(rows[0]["content"].array.count, 2)
      XCTAssertEqual(body["tools"], .null)
      XCTAssertEqual(body["previous_response_id"], .null)
      if format == .responses { XCTAssertEqual(body["store"], .bool(false)) }
    }
  }
  func testSSEByteFramingUnicodeCRLFAndMultipleDataLines() throws {
    var decoder = SSEDecoder(); var events = [String]()
    for byte in Data(": comment\r\ndata: 你好🌿\r\ndata: 下一行\r\n\r\ndata: [DONE]\n\n".utf8) {
      if let event = try decoder.consume(byte: byte) { events.append(event) }
    }
    XCTAssertEqual(events, ["你好🌿\n下一行", "[DONE]"])
  }
  func testEndpointsDisallowCredentialURLsAndInsecureRemoteHosts() throws {
    var p = APIProfile()
    for invalid in ["http://example.com/v1", "https://user:pass@example.com", "https://example.com?key=secret", "file:///tmp/test"] {
      p.baseURL = invalid; XCTAssertThrowsError(try p.endpoint("models"))
    }
    p.baseURL = "http://127.0.0.1:1234/v1"
    XCTAssertEqual(try p.endpoint("chat/completions").path, "/v1/chat/completions")
  }
  func testChatGPTImportUsesCurrentBranchAndSkipsHiddenContent() throws {
    let raw = #"[{"id":"c1","title":"导出","current_node":"chosen","mapping":{"root":{"message":null,"children":["user"]},"user":{"parent":"root","message":{"id":"m1","author":{"role":"user"},"content":{"parts":["你好"]}},"children":["other","chosen"]},"other":{"parent":"user","message":{"author":{"role":"assistant"},"content":{"parts":["错误分支"]}}},"chosen":{"parent":"user","message":{"id":"m2","author":{"role":"assistant"},"content":{"parts":["选定分支"]}}}}}]"#
    let c = try ChatGPTImport.parse(Data(raw.utf8), cwd: "/tmp")[0]
    XCTAssertEqual(c.items.map(\.text), ["你好", "选定分支"])
    XCTAssertEqual(c.engine, .chatgptArchive)
    XCTAssertEqual(c.importID, "chatgpt:c1")
    XCTAssertTrue(c.isGPT)
  }
  func testCodexDisconnectDoesNotFailAPIRequest() {
    var c = Conversation(cwd: "/tmp"); c.backend = .api; c.status = .running
    var state = EventState(conversations: [c]); state.invalidateConnection()
    XCTAssertEqual(state.conversations[0].status, .running)
  }
}
