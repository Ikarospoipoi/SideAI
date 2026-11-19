import XCTest
import SideAICore
@testable import SideAI
final class MemoryLiveTests: XCTestCase {
  @MainActor func testOptInSyntheticHistoryTools() async throws {
    guard ProcessInfo.processInfo.environment["SIDEAI_MEMORY_LIVE"] == "1" else { throw XCTSkip("Opt-in synthetic GPT history tool verification") }
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SideAI")
    let saved = try XCTUnwrap(try Persistence(directory: directory).load())
    let profile = try XCTUnwrap(saved.settings.apiProfiles?.first { $0.auth == .chatgptPlan })
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = SessionStore(directory: temp); defer { store.shutdown() }
    store.settings.apiProfiles = [profile]
    let key = try await store.credential(for: profile)
    var c = Conversation(cwd: temp.path); c.backend = .api; c.profileID = profile.id; c.reasoningEffort = "low"
    c.items = [TimelineItem(kind: "userMessage", text: "这是合成工具测试。请先搜索 SideAI测试 的历史，然后调用 read_history 读取找到的会话，最后只回答其中的测试词。")]
    var old = Conversation(cwd: temp.path); old.title = "SideAI测试"; old.items = [TimelineItem(kind: "agentMessage", text: "测试词是青竹42")]
    let client = HTTPChatClient(); defer { client.cancel() }
    var names = [String]()
    let body = try APIRequestBuilder.body(conversation: c, format: .responses, model: "gpt-6-astra")
    let answer = try await client.streamWithMemory(profile: profile, key: key, body: body, execute: { name, args in
      names.append(name)
      return try MemoryTools.execute(name: name, arguments: args, current: c, conversations: [old]).0
    }, update: { _ in })
    XCTAssertTrue(names.contains("search_history")); XCTAssertTrue(names.contains("read_history"))
    XCTAssertTrue(answer.contains("青竹42"))
    print("MEMORY_LIVE tools=\(names.joined(separator: ",")) synthetic_answer_matched=\(answer.contains("青竹42"))")
  }
}
