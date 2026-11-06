import AppKit
import SideAICore
import SwiftUI

struct ConnectionManagerView: View {
  @ObservedObject var store: SessionStore
  var configure: () -> Void
  @State private var pending: ConnectionRoute?
  @State private var reset = false
  @State private var notice = ""
  var body: some View {
    Form {
      Section {
        HStack { Text("我的连接").font(.title2.bold()); Spacer(); Button("添加连接", action: configure) }
        if store.routes.isEmpty { Text("还没有连接。添加一个 AI，开始第一次对话。").foregroundStyle(.secondary) }
      }
      ForEach(WorkspaceMode.allCases, id: \.rawValue) { workspace in
        let routes = store.routes.filter { $0.workspace == workspace }
        if !routes.isEmpty {
          Section(workspace.label) {
            ForEach(routes) { route in
              VStack(alignment: .leading, spacing: 8) {
                Text(route.name).font(.headline).foregroundStyle(route.provider.accentColor)
                HStack {
                  Button("打开") { store.switchConnection(route) }
                  if let profile = store.profiles.first(where: { $0.id == route.profileID }) {
                    if profile.auth == .apiKey { Button("编辑") { store.editingProfileID = profile.id; configure() } }
                    else { Button("重新登录") { configure(); if profile.auth == .chatgptPlan { store.signInChatGPT(profile) } else { store.signInOpenRouter(profile) } } }
                    Menu("更多") { Button("允许钥匙串访问") { store.authorizeCredential(profile) } }
                  } else if let runtime = AccountRuntime.allCases.first(where: { $0.route.id == route.id }) {
                    Button("重新登录") { configure(); store.signInRuntime(runtime) }
                  } else if route.workspace == .agent { Button("重新登录") { configure(); store.signInAgent(route) } }
                  Spacer()
                  Button("删除连接", role: .destructive) { pending = route }
                }.controlSize(.small).disabled(store.isBusy || store.chatgptSigningIn)
              }.padding(.vertical, 4)
            }
          }
        }
      }
      if !store.connectionNotice.isEmpty { Section { Text(store.connectionNotice).font(.caption).textSelection(.enabled) } }
      if !notice.isEmpty { Section { Text(notice).font(.caption).textSelection(.enabled) } }
      Section {
        Button("从头开始…", role: .destructive) { reset = true }.disabled(store.isBusy || store.chatgptSigningIn)
        Text("清空 SideAI 的连接和登录状态，旧对话保存到本机备份。").font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
      .alert("删除这个连接？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { route in
        Button("取消", role: .cancel) { pending = nil }
        Button("删除", role: .destructive) {
          Task { do { try await store.disconnectConnection(route); notice = "" } catch { notice = error.localizedDescription } }
          pending = nil
        }
      } message: { _ in Text("删除在 SideAI 中保存的连接与登录凭据。对话保留；再次使用需要重新连接。") }
      .alert("从头开始体验？", isPresented: $reset) {
        Button("取消", role: .cancel) { }
        Button("清空并开始", role: .destructive) {
          Task { do { try await store.resetOnboarding(); notice = "已重置。点击添加连接开始。" } catch { notice = error.localizedDescription } }
        }
      } message: { Text("解除所有 AI 和 Agent 连接，清除 SideAI 保存的凭据。旧对话会另存为本机备份，不影响其他软件的账号。") }
  }
}
