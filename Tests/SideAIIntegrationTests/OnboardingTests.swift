import XCTest
import SideAICore
@testable import SideAI

final class OnboardingTests: XCTestCase {
  @MainActor func testFreshStartAndResetHaveNoImplicitConnectionsAndKeepBackup() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    XCTAssertTrue(store.routes.isEmpty); XCTAssertTrue(store.state.conversations.isEmpty); XCTAssertNil(store.selectedID)
    XCTAssertTrue(store.settings.isolatedAgentLogin == true)
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.settings.connectedAgentIDs = [ConnectionRoute.codex.id, ConnectionRoute.claude.id]; store.settings.connectedRuntimes = [.kimi, .gemini]
    store.newConversation(route: .api(p)); let id = try XCTUnwrap(store.selectedID); store.mutate(id) { $0.draft = "备份草稿" }
    var deleted = [UUID]()
    try await store.resetOnboarding { deleted.append($0) }
    XCTAssertEqual(deleted, [p.id]); XCTAssertTrue(store.routes.isEmpty); XCTAssertNil(store.selectedID); XCTAssertTrue(store.state.conversations.isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
    let backup = try XCTUnwrap(Persistence(directory: XCTUnwrap(backups.first)).load())
    XCTAssertEqual(backup.conversations.first?.draft, "备份草稿")
    let reloaded = SessionStore(directory: dir); defer { reloaded.shutdown() }
    XCTAssertTrue(reloaded.routes.isEmpty); XCTAssertTrue(reloaded.state.conversations.isEmpty)
  }
  @MainActor func testAccountRoutesPersistWithoutDuplicateEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    store.settings.connectedRuntimes = [.kimi, .gemini]
    store.newConversation(route: AccountRuntime.kimi.route)
    let id = try XCTUnwrap(store.selectedID); store.mutate(id) { $0.draft = "Kimi 草稿" }
    store.newConversation(route: AccountRuntime.gemini.route)
    XCTAssertEqual(store.workspaceRoutes.count, 2)
    store.accountModels[.kimi] = [] // Do not start a real CLI from a routing test.
    store.switchConnection(AccountRuntime.kimi.route)
    XCTAssertEqual(store.selectedID, id); XCTAssertEqual(store.selected?.draft, "Kimi 草稿")
    store.saveNow()
    let reloaded = SessionStore(directory: dir); defer { reloaded.shutdown() }
    XCTAssertEqual(reloaded.routes.count, 2); XCTAssertEqual(reloaded.selected?.accountRuntime, .kimi)
  }
  func testOfficialRuntimeToolIsolationAndPromptFiltering() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    for runtime in AccountRuntime.allCases {
      let cwd = try RuntimeEnvironment.prepare(runtime, root: dir)
      XCTAssertTrue(cwd.path.hasPrefix(dir.path))
      let env = try RuntimeEnvironment.isolated(path: "/usr/bin/false", key: runtime.environmentKey, name: runtime.rawValue, root: dir)
      XCTAssertTrue(env[runtime.environmentKey]!.hasPrefix(dir.path)); XCTAssertNil(env["OPENAI_API_KEY"]); XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }
    let gemini = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: dir.appendingPathComponent("Accounts/gemini/sideai/settings.json")))
    XCTAssertEqual(gemini["toolPermission"].text, "strict")
    XCTAssertTrue(gemini["permissions"]["deny"].array.contains(.string("read_file(*)")))
    let googleAgent = try String(contentsOf: dir.appendingPathComponent("Scratch/Accounts/gemini/.agents/agents/sideai-chat.md"))
    XCTAssertTrue(googleAgent.contains("tools: []")); XCTAssertTrue(googleAgent.contains("subagent: false"))
    let googleArgs = try RuntimeEnvironment.arguments(.gemini, root: dir)
    XCTAssertFalse(googleArgs[try XCTUnwrap(googleArgs.firstIndex(of: "--app-data-dir")) + 1].hasPrefix("/"))
    XCTAssertEqual(AccountRuntime.gemini.executable, "agy")
    let agent = try String(contentsOf: dir.appendingPathComponent("Scratch/Accounts/kimi/.kimi-code/agents/agent.md"))
    XCTAssertTrue(agent.contains("tools: []")); XCTAssertTrue(agent.contains("subagents: []"))
    let grok = try RuntimeEnvironment.arguments(.grok, root: dir)
    XCTAssertEqual(grok[try XCTUnwrap(grok.firstIndex(of: "--tools")) + 1], ""); XCTAssertTrue(grok.contains("dontAsk"))
    var c = Conversation(cwd: "/tmp"); c.draft = "新问题"
    c.items = [TimelineItem(kind: "userMessage", text: "上下文"), TimelineItem(kind: "agentMessage", text: "回答"), TimelineItem(kind: "reasoning", text: "私有推理"), TimelineItem(kind: "toolCall", text: "工具日志"), TimelineItem(kind: "agentMessage", text: "未完成", status: "failed")]
    let prompt = try AccountClient.prompt(c).pretty
    XCTAssertTrue(prompt.contains("上下文")); XCTAssertTrue(prompt.contains("新问题")); XCTAssertFalse(prompt.contains("私有推理")); XCTAssertFalse(prompt.contains("工具日志")); XCTAssertFalse(prompt.contains("未完成"))
  }
  @MainActor func testACPStreamingRejectsToolRequestsAndHandlesCancellation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appendingPathComponent("fake-acp")
    try #"""
#!/usr/bin/env python3
import sys,json
for line in sys.stdin:
 r=json.loads(line); m=r.get('method'); i=r.get('id')
 if not m: continue
 if m=='initialize': result={'authMethods':[{'id':'login'}]}
 elif m=='session/new': result={'sessionId':'s','models':{'availableModels':[{'modelId':'test','name':'Test model'}]}}
 elif m=='session/prompt':
  print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'真实分片'}}}}),flush=True)
  result={'stopReason':'end_turn'}
 elif m=='tool-test':
  print(json.dumps({'jsonrpc':'2.0','id':'permission','method':'session/request_permission','params':{}}),flush=True)
  answer=json.loads(sys.stdin.readline()); result=answer['result']
 elif m=='wait': continue
 else: result={}
 print(json.dumps({'jsonrpc':'2.0','id':i,'result':result}),flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = AccountClient(root: dir); defer { client.stop() }
    _ = try await client.start(runtime: .kimi, path: script.path)
    let session = try await client.newSession(.kimi); XCTAssertEqual(AccountClient.models(session).first?.id, "test")
    var text = ""; client.onText = { text = $0 }
    let response = try await client.request("session/prompt", .object([:])); XCTAssertEqual(response["stopReason"].text, "end_turn"); XCTAssertEqual(text, "真实分片")
    let denied = try await client.request("tool-test", .object([:])); XCTAssertEqual(denied["outcome"]["outcome"].text, "cancelled")
    let task = Task { try await client.request("wait", .object([:])) }
    await Task.yield(); task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation must finish pending requests") } catch { XCTAssertTrue(error is CancellationError) }
  }
}
