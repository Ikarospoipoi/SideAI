import XCTest
import SideAICore
@testable import SideAI

final class ConnectionFeedbackStoreTests: XCTestCase {
  @MainActor private func withStore(_ body: (SessionStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(directory: directory)
    defer { store.shutdown() }
    try body(store)
  }

  @MainActor func testConfiguredDoesNotClaimSuccessfulRequestAndFailuresReplaceSuccess() throws {
    try withStore { store in
      let profile = ProviderKind.deepseek.preset(), other = ProviderKind.kimi.preset()
      store.settings.apiProfiles = [profile, other]; store.newConversation(route: .api(profile))
      XCTAssertEqual(store.currentConnectionStatus, "已配置 · 尚未验证请求")
      store.recordConnectionFeedback(ConnectionFeedback(title: "上次请求成功"), for: .api(profile))
      let message = store.connectionFailureMessage(URLError(.timedOut), for: .api(profile))
      XCTAssertEqual(store.currentConnectionStatus, "上次请求失败")
      XCTAssertTrue(message.contains("未自动重发"))
      XCTAssertTrue(message.contains("可能已送达"))
      store.newConversation(route: .api(other))
      XCTAssertEqual(store.currentConnectionStatus, "已配置 · 尚未验证请求")
      store.recordConnectionFeedback(ConnectionFeedback(title: "请求已停止"), for: .api(profile))
      XCTAssertEqual(store.connectionFeedback(for: .api(profile))?.title, "请求已停止")
    }
  }

  @MainActor func testOfficialAccountAndCodexDoNotOverstateAvailability() throws {
    try withStore { store in
      let runtime = AccountRuntime.allCases[0]
      store.settings.connectedRuntimes = [runtime]; store.newConversation(route: runtime.route)
      XCTAssertEqual(store.currentConnectionStatus, "已配置 · 尚未验证请求")
      store.settings.connectedAgentIDs = [ConnectionRoute.codex.id]; store.newConversation(route: .codex)
      store.connecting = true
      XCTAssertEqual(store.currentConnectionStatus, "正在连接 Codex…")
      store.connecting = false; store.ready = true
      XCTAssertEqual(store.currentConnectionStatus, "Codex 执行器已连接")
    }
  }

  @MainActor func testEditingAndRestoringProfileInvalidatePreviousSuccess() throws {
    try withStore { store in
      var profile = ProviderKind.deepseek.preset()
      store.settings.apiProfiles = [profile]; store.newConversation(route: .api(profile))
      store.recordConnectionFeedback(ConnectionFeedback(title: "上次请求成功"), for: .api(profile))
      profile.defaultModel = "another-model"
      try store.saveProfile(profile, key: "")
      XCTAssertEqual(store.currentConnectionStatus, "已配置 · 尚未验证请求")
      store.recordConnectionFeedback(ConnectionFeedback(title: "上次请求成功"), for: .api(profile))
      try store.removeConnection(.api(profile), deleteCredential: { _ in })
      XCTAssertEqual(store.connectionFeedback(for: .api(profile))?.title, "连接配置已移除")
      try store.restoreConnection(profile.routeID)
      XCTAssertEqual(store.connectionFeedback(for: .api(profile))?.title, "已配置 · 尚未验证请求")
    }
  }

  @MainActor func testFeedbackIsTransientAndDoesNotChangeDraftOrRetry() throws {
    try withStore { store in
      let profile = ProviderKind.deepseek.preset()
      store.settings.apiProfiles = [profile]; store.newConversation(route: .api(profile))
      store.mutate(store.selectedID!) { $0.draft = "保留的草稿" }
      _ = store.connectionFailureMessage(URLError(.cannotConnectToHost), for: .api(profile))
      XCTAssertEqual(store.selected?.draft, "保留的草稿")
      XCTAssertTrue(store.apiTasks.isEmpty); XCTAssertTrue(store.apiClients.isEmpty)
      store.saveNow()
      let restored = SessionStore(directory: store.persistence.directory); defer { restored.shutdown() }
      XCTAssertEqual(restored.currentConnectionStatus, "已配置 · 尚未验证请求")
      XCTAssertEqual(restored.selected?.draft, "保留的草稿")
    }
  }

  @MainActor func testClaudePresentationIsExcludedWithoutStartingAnyClient() throws {
    try withStore { store in
      // Inspect presentation guards only. Never switch to or refresh a Claude connection.
      XCTAssertNil(store.connectionFeedback(for: .claude))
      XCTAssertNil(store.connectionFeedback(for: .claudeChat))
      var profile = ProviderKind.anthropic.preset()
      store.settings.apiProfiles = [profile]
      XCTAssertFalse(store.supportsConnectionFeedback(.api(profile)))
      profile = ProviderKind.openrouter.preset(); profile.defaultModel = "anthropic/claude-test"
      store.settings.apiProfiles = [profile]
      XCTAssertFalse(store.supportsConnectionFeedback(.api(profile)))
      XCTAssertTrue(store.connectionFeedbackByRoute.isEmpty)
      XCTAssertTrue(store.claudeClients.isEmpty)
    }
  }
}
