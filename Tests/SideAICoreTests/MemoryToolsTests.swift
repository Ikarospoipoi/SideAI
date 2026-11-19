import XCTest
@testable import SideAICore
final class MemoryToolsTests: XCTestCase {
  func testSearchPaginationAndReadExclusions() throws {
    let current = Conversation(cwd: "/tmp")
    var docs = (0..<12).map { i -> Conversation in
      var c = Conversation(cwd: "/tmp"); c.title = "SQL \(i)"
      c.items = [TimelineItem(kind: "agentMessage", text: "SELECT \(i)"), TimelineItem(kind: "reasoning", text: "hidden")]
      return c
    }
    docs[0].memoryExcluded = true
    let (first, sources) = try MemoryTools.execute(name: "search_history", arguments: #"{"query":"SQL","offset":0}"#, current: current, conversations: docs)
    XCTAssertEqual(sources.count, 8); XCTAssertEqual(first["next_offset"], .number(8))
    let (_, more) = try MemoryTools.execute(name: "search_history", arguments: #"{"query":"SQL","offset":8}"#, current: current, conversations: docs)
    XCTAssertEqual(more.count, 3); XCTAssertTrue(Set(sources.map(\.id)).isDisjoint(with: more.map(\.id)))
    func read(_ id: UUID) throws -> JSON {
      try MemoryTools.execute(name: "read_history", arguments: "{\"conversation_id\":\"\(id.uuidString)\",\"offset\":0}", current: current, conversations: docs).0
    }
    XCTAssertThrowsError(try read(docs[0].id)); XCTAssertThrowsError(try read(current.id))
    XCTAssertFalse(try read(docs[1].id).pretty.contains("hidden"))
    for args in [#"{"query":"SQL","offset":-1}"#, #"{"query":"SQL","offset":0.5}"#, #"{"query":"SQL","offset":0,"path":"/tmp"}"#] {
      XCTAssertThrowsError(try MemoryTools.execute(name: "search_history", arguments: args, current: current, conversations: docs))
    }
  }
  func testLongConversationReadCanContinueWithoutLosingUnicode() throws {
    let current = Conversation(cwd: "/tmp")
    var old = Conversation(cwd: "/tmp"); old.items = [TimelineItem(kind: "userMessage", text: String(repeating: "🌿", count: 9000))]
    let (first, _) = try MemoryTools.execute(name: "read_history", arguments: "{\"conversation_id\":\"\(old.id)\",\"offset\":0}", current: current, conversations: [old])
    XCTAssertEqual(first["next_offset"], .number(8000))
    let (next, _) = try MemoryTools.execute(name: "read_history", arguments: "{\"conversation_id\":\"\(old.id)\",\"offset\":8000}", current: current, conversations: [old])
    XCTAssertEqual(next["next_offset"], .null)
    let combined = first["sources"].array[0]["excerpt"].text + next["sources"].array[0]["excerpt"].text
    XCTAssertEqual(combined, "用户：" + old.items[0].text)
  }
}
