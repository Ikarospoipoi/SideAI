import XCTest

@testable import SideAICore

final class CoreTests: XCTestCase {
  func json(_ s: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(s.utf8)) }
  func testFramingEveryUTF8BoundaryAndBatchedMessages() throws {
    let bytes = Data("{\"method\":\"你好🌿\"}\n{\"id\":2,\"result\":{}}\n".utf8)
    for boundary in 0...bytes.count {
      var framer = JSONLineFramer()
      let messages =
        try framer.append(bytes.prefix(boundary)) + framer.append(bytes.dropFirst(boundary))
      XCTAssertEqual(messages.count, 2)
      XCTAssertEqual(messages[0]["method"].text, "你好🌿")
      XCTAssertEqual(messages[1]["id"], .number(2))
    }
  }
  func testMalformedFrameFailsInsteadOfSilentlyLosingEvents() {
    var framer = JSONLineFramer()
    XCTAssertThrowsError(try framer.append(Data("not-json\n".utf8)))
  }
  func testIDTypeIsPreserved() throws {
    XCTAssertNotEqual(JSON.string("1").key, JSON.number(1).key)
    XCTAssertEqual(
      try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(JSON.string("approval-17"))),
      .string("approval-17"))
  }
  func testRoutingAndFinalEventDeduplication() throws {
    var a = Conversation(cwd: "/tmp/a")
    var b = Conversation(cwd: "/tmp/b")
    a.threadID = "A"
    b.threadID = "B"
    var state = EventState(conversations: [a, b])
    state.receive(
      try json(
        #"{"method":"item/started","params":{"threadId":"A","item":{"id":"m1","type":"agentMessage","text":""}}}"#
      ))
    state.receive(
      try json(
        #"{"method":"item/agentMessage/delta","params":{"threadId":"A","itemId":"m1","delta":"你好"}}"#
      ))
    XCTAssertEqual(state.conversations[0].items[0].text, "你好")
    XCTAssertTrue(state.conversations[1].items.isEmpty)
    let final = try json(
      #"{"method":"item/completed","params":{"threadId":"A","item":{"id":"m1","type":"agentMessage","text":"你好，世界"}}}"#
    )
    state.receive(final)
    state.receive(final)
    state.receive(
      try json(
        #"{"method":"item/agentMessage/delta","params":{"threadId":"A","itemId":"m1","delta":"late"}}"#
      ))
    XCTAssertEqual(state.conversations[0].items.count, 1)
    XCTAssertEqual(state.conversations[0].items[0].text, "你好，世界")
  }
  func testApprovalQueueResolutionAndConnectionInvalidation() throws {
    var c = Conversation(cwd: "/tmp/test")
    c.threadID = "A"
    c.turnID = "t1"
    c.status = .running
    var state = EventState(conversations: [c])
    let first = try json(
      #"{"id":"r1","method":"item/commandExecution/requestApproval","params":{"threadId":"A","turnId":"t1","itemId":"i1","command":"echo hello"}}"#
    )
    XCTAssertTrue(state.receive(first))
    XCTAssertFalse(state.receive(first))
    state.receive(
      try json(
        #"{"id":2,"method":"item/commandExecution/requestApproval","params":{"threadId":"A","turnId":"t1","itemId":"i1","command":"echo again"}}"#
      ))
    XCTAssertEqual(state.pending.count, 2)
    state.pending[0].submitted = true
    XCTAssertEqual(state.conversations[0].status, .awaitingApproval)
    state.receive(
      try json(#"{"method":"serverRequest/resolved","params":{"threadId":"A","requestId":"r1"}}"#))
    XCTAssertEqual(state.pending.count, 1)
    XCTAssertEqual(state.pending[0].requestID, .number(2))
    XCTAssertFalse(state.receive(first), "A resolved request must never become clickable again")
    XCTAssertEqual(state.pending.count, 1)
    let generation = state.generation
    state.invalidateConnection()
    XCTAssertNotEqual(state.generation, generation)
    XCTAssertTrue(state.pending.isEmpty)
    XCTAssertEqual(state.conversations[0].status, .failed)
  }
  func testStaleTurnCompletionDoesNotFinishNewTurn() throws {
    var c = Conversation(cwd: "/tmp")
    c.threadID = "A"
    c.turnID = "new"
    c.status = .running
    var state = EventState(conversations: [c])
    state.receive(
      try json(
        #"{"method":"turn/completed","params":{"threadId":"A","turn":{"id":"old","status":"completed"}}}"#
      ))
    XCTAssertEqual(state.conversations[0].status, .running)
  }
  func testPersistenceRetainsDraftAndDoesNotRestoreRunningOrApproval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = Persistence(directory: root)
    var c = Conversation(cwd: "/tmp")
    c.draft = "未发送的中文草稿"
    c.threadID = "A"
    c.turnID = "turn"
    c.status = .awaitingApproval
    try p.save(Snapshot(conversations: [c], selectedID: c.id))
    let loaded = try XCTUnwrap(p.load())
    XCTAssertEqual(loaded.conversations[0].draft, c.draft)
    XCTAssertEqual(loaded.conversations[0].threadID, "A")
    XCTAssertEqual(loaded.conversations[0].status, .interrupted)
    XCTAssertNil(loaded.conversations[0].turnID)
    XCTAssertEqual(loaded.selectedID, c.id)
  }
  func testCorruptPersistenceDoesNotOverwriteOnRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("state.json")
    let bytes = Data("broken".utf8)
    try bytes.write(to: file)
    XCTAssertThrowsError(try Persistence(directory: root).load())
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  func testPanelPinAndToggleTransitions() {
    var state = PanelState.collapsed
    state.toggle()
    XCTAssertEqual(state, .expanded)
    state.outsideClick()
    XCTAssertEqual(state, .collapsed)
    state = .pinned
    state.outsideClick()
    XCTAssertEqual(state, .pinned)
    state.toggle()
    XCTAssertEqual(state, .collapsed)
  }
  func testProjectPolicyDoesNotGrantWholeHomeOrNetwork() {
    let policy = AgentMode.project.policy(cwd: "/tmp/test-project")
    XCTAssertEqual(policy["writableRoots"].array, [.string("/tmp/test-project")])
    XCTAssertFalse(policy["networkAccess"].bool)
    XCTAssertTrue(policy["excludeSlashTmp"].bool)
    XCTAssertEqual(AgentMode.readOnly.policy(cwd: "/tmp")["type"].text, "readOnly")
  }
}
