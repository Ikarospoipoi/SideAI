import XCTest
import SideAICore
@testable import SideAI

final class WorkspaceTests: XCTestCase {
  @MainActor func testLegacyMigrationPreservesConnectionsDraftsAndAgentState() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let profile = ProviderKind.openai.preset()
    var codex = Conversation(cwd: "/tmp/project"); codex.threadID = "real-thread"; codex.draft = "原任务"
    var claude = Conversation(cwd: "/tmp"); claude.backend = .claude; claude.claudeSessionID = UUID().uuidString; claude.claudeHasSession = true; claude.draft = "旧 CC"
    var chat = Conversation(cwd: "/tmp"); chat.backend = .api; chat.profileID = profile.id; chat.draft = "原聊天"; chat.modelID = "kept-model"
    var settings = AppSettings(); settings.apiProfiles = [profile]; settings.activeRoutes = ["openai": "codex-local", "anthropic": "claude-local"]
    try Persistence(directory: dir).save(Snapshot(settings: settings, conversations: [codex, claude, chat], selectedID: codex.id))
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    XCTAssertEqual(store.workspace, .chat); XCTAssertEqual(store.selectedID, chat.id)
    XCTAssertTrue(store.isRouteActive(.codex)); XCTAssertTrue(store.isRouteActive(.api(profile)))
    XCTAssertEqual(store.selected?.draft, "原聊天"); XCTAssertEqual(store.selected?.modelID, "kept-model")
    store.switchWorkspace(.agent)
    XCTAssertEqual(store.selectedID, codex.id); XCTAssertEqual(store.selected?.threadID, "real-thread")
    XCTAssertNil(store.state.conversations.first { $0.id == claude.id }?.claudeAgentEnabled)
    store.switchWorkspace(.chat); XCTAssertEqual(store.selectedID, chat.id)
  }
  @MainActor func testMigrationKeepsPreviouslyActiveAPIAmongSameProviderProfiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = ProviderKind.openai.preset(), chosen = ProviderKind.openai.preset()
    var settings = AppSettings(); settings.apiProfiles = [first, chosen]
    settings.activeRoutes = [ConnectionRoute.api(chosen).groupID: ConnectionRoute.api(chosen).id]
    try Persistence(directory: dir).save(Snapshot(settings: settings, conversations: [], selectedID: nil))
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    XCTAssertTrue(store.isRouteActive(.api(chosen)))
    XCTAssertFalse(store.isRouteActive(.api(first)))
    XCTAssertTrue(store.isRouteActive(.codex))
  }
  @MainActor func testHandoffIsUnsentDraftAndRoundTripKeepsOriginalDraft() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    store.settings.connectedAgentIDs = [ConnectionRoute.codex.id, ConnectionRoute.claude.id]
    let p = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [p]; store.newConversation(route: .api(p))
    let sourceID = try XCTUnwrap(store.selectedID)
    store.mutate(sourceID) { $0.draft = "原草稿"; $0.items = [TimelineItem(kind: "agentMessage", text: "公开背景"), TimelineItem(kind: "reasoning", text: "不应复制"), TimelineItem(kind: "toolCall", text: "不能复制的工具调用")] }
    let source = try XCTUnwrap(store.selected)
    let context = HandoffBuilder.transcript(source, ids: Set(source.items.map(\.id)))
    XCTAssertEqual(context, "助手：公开背景")
    store.createHandoff(source: source, route: .claude, task: "检查文件", context: context, images: [], memory: "可选记忆", cwd: "/tmp/project", mode: .readOnly)
    let child = try XCTUnwrap(store.selected)
    XCTAssertEqual(store.workspace, .agent); XCTAssertEqual(child.handoff?.sourceID, sourceID)
    XCTAssertTrue(child.items.isEmpty); XCTAssertNil(child.threadID); XCTAssertNil(child.claudeSessionID)
    XCTAssertEqual(child.status, .idle); XCTAssertTrue(child.claudeAgentEnabled == true)
    XCTAssertTrue(child.draft.contains("可选记忆")); XCTAssertEqual(child.cwd, "/tmp/project")
    XCTAssertTrue(store.claudeClients.isEmpty); XCTAssertTrue(store.apiClients.isEmpty)
    store.mutate(child.id) { $0.items.append(TimelineItem(kind: "agentMessage", text: "已检查")) }
    store.bringResultBack()
    XCTAssertEqual(store.selectedID, sourceID); XCTAssertTrue(store.selected!.draft.hasPrefix("原草稿")); XCTAssertTrue(store.selected!.draft.contains("已检查"))
    XCTAssertEqual(store.selected?.items.count, 3)
  }
  @MainActor func testClaudeAccountChatIsIsolatedFromAgentAndCannotEnableTools() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(directory: dir); defer { store.shutdown() }
    store.settings.connectedAgentIDs = [ConnectionRoute.codex.id, ConnectionRoute.claude.id]
    store.settings.claudeChatEnabled = true
    store.newConversation(route: .claude)
    let agentID = try XCTUnwrap(store.selectedID)
    store.mutate(agentID) { $0.draft = "原 Agent 草稿" }
    store.newConversation(route: .claudeChat)
    let chatID = try XCTUnwrap(store.selectedID)
    XCTAssertNotEqual(agentID, chatID); XCTAssertEqual(store.workspace, .chat)
    XCTAssertEqual(store.selected?.routeID, ConnectionRoute.claudeChat.id)
    XCTAssertTrue(store.isRouteActive(.claude)); XCTAssertTrue(store.isRouteActive(.claudeChat))
    var c = try XCTUnwrap(store.selected); c.claudeSessionID = UUID().uuidString; c.claudeAgentEnabled = true; c.mode = .project
    XCTAssertTrue(ClaudePermissions.tools(for: c).isEmpty)
    let args = try ClaudeProtocol.arguments(conversation: c)
    XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "")
    XCTAssertTrue(args.contains("dontAsk")); XCTAssertFalse(args.contains("--permission-prompt-tool"))
    store.switchWorkspace(.agent); XCTAssertEqual(store.selectedID, agentID); XCTAssertEqual(store.selected?.draft, "原 Agent 草稿")
    try store.removeConnection(.claudeChat)
    XCTAssertTrue(store.routes.contains(.claude)); XCTAssertFalse(store.routes.contains(.claudeChat))
    try store.restoreConnection(ConnectionRoute.claudeChat.id)
    store.switchWorkspace(.chat); XCTAssertEqual(store.selectedID, chatID)
    store.saveNow()
    let restored = SessionStore(directory: dir); defer { restored.shutdown() }
    XCTAssertEqual(restored.selected?.workspace, .chat); XCTAssertEqual(restored.selected?.claudeChatOnly, true)
  }
  func testDuplicateIdentityAndReadOnlyClaudeToolBoundary() throws {
    var a = ProviderKind.openai.preset(), b = ProviderKind.openai.preset()
    XCTAssertTrue(a.duplicates(b)); b.accountLabel = "工作账号"; XCTAssertFalse(a.duplicates(b))
    b.accountLabel = nil; b.authentication = .chatgptPlan; XCTAssertFalse(a.duplicates(b))
    a.authentication = .chatgptPlan; a.oauthClientID = "one"; b.oauthClientID = "two"; XCTAssertFalse(a.duplicates(b))
    var c = Conversation(cwd: "/tmp"); c.backend = .claude; c.claudeAgentEnabled = true; c.claudeSessionID = UUID().uuidString
    XCTAssertFalse(ClaudePermissions.tools(for: c).contains("Write")); XCTAssertFalse(ClaudePermissions.tools(for: c).contains("Bash"))
    c.mode = .project; let args = try ClaudeProtocol.arguments(conversation: c)
    XCTAssertTrue(args.contains("--restricted")); XCTAssertTrue(args.contains("stdio")); XCTAssertTrue(ClaudePermissions.tools(for: c).contains("Edit"))
    XCTAssertFalse(args.contains("bypassPermissions"))
  }
  func testOAuthLoopbackRejectsUnrelatedStateAndAcceptsExpectedCallback() async throws {
    let listener = OAuthLoopback(); defer { listener.cancel() }
    let port = try await listener.start(); listener.prepare(state: "expected")
    let task = Task { try await listener.callback(state: "expected") }
    let (_, wrong) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?state=wrong&code=x")!)
    XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 400)
    let (_, right) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?state=expected&code=x&client_id=issued")!)
    XCTAssertEqual((right as? HTTPURLResponse)?.statusCode, 200)
    let callback = try await task.value
    XCTAssertTrue(callback.absoluteString.contains("state=expected"))
  }
}
