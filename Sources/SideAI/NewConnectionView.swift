import AppKit
import SideAICore
import SwiftUI

struct ConnectionsSettings: View {
  @ObservedObject var store: SessionStore
  @State private var section = WorkspaceMode.chat
  @State private var editing: APIProfile?
  @State private var advanced = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text("添加连接").font(.title2.bold()); Spacer() }
      Text("选一个 AI，按提示登录。完成后，它会出现在你的首页。").foregroundStyle(.secondary)
      Picker("用途", selection: $section) { Text("聊天").tag(WorkspaceMode.chat); Text("Agent · 处理项目").tag(WorkspaceMode.agent) }.pickerStyle(.segmented)
      ScrollView {
        VStack(spacing: 10) {
          if section == .chat {
            providerRow("GPT", provider: .openai, detail: "使用 ChatGPT 账号", action: "Continue with ChatGPT") { store.signInChatGPT() }
            providerRow("Kimi", provider: .kimi, detail: "使用 Kimi Code 账号", action: "登录 Kimi") { store.signInRuntime(.kimi) }
            providerRow("Gemini", provider: .gemini, detail: "使用 Google 账号 · Antigravity", action: "使用 Google 登录") { store.signInRuntime(.gemini) }
            providerRow("Grok", provider: .grok, detail: "使用 Grok 账号 · Grok Build", action: "登录 Grok") { store.signInRuntime(.grok) }
            providerRow("OpenRouter", provider: .openrouter, detail: "一个账号，选择多家模型 · 使用 OpenRouter 余额", action: "登录 OpenRouter") { store.signInOpenRouter() }
            providerRow("Claude", provider: .anthropic, detail: "直接聊天使用 API；Claude Code 账号请在 Agent 中登录", action: "连接 API") { editing = ProviderKind.anthropic.preset() }
            providerRow("DeepSeek", provider: .deepseek, detail: "使用 DeepSeek API 密钥", action: "连接 API") { editing = ProviderKind.deepseek.preset() }
            providerRow("Qwen", provider: .qwen, detail: "使用通义千问 API 密钥", action: "连接 API") { editing = ProviderKind.qwen.preset() }
            DisclosureGroup("其他接入方式", isExpanded: $advanced) {
              HStack {
                Button("Gemini 企业账号登录") { store.signInRuntime(.gemini, business: true) }.disabled(store.isBusy)
                Menu("使用 API 密钥") { ForEach(ProviderKind.allCases, id: \.rawValue) { p in Button(p.label) { editing = p.preset() } } }
                Spacer()
              }.padding(.top, 8)
            }.padding(12)
          } else {
            providerRow("Codex", provider: .openai, detail: "使用 ChatGPT 账号", action: "登录 Codex") { store.signInAgent(.codex) }
            providerRow("Claude Code", provider: .anthropic, detail: "在官方页面登录你的 Claude 账号", action: "登录 Claude Code") { store.signInAgent(.claude) }
            DisclosureGroup("高级设置") {
              VStack(alignment: .leading, spacing: 10) {
                TextField("Codex 程序路径（自动查找）", text: $store.settings.cliPath)
                TextField("Claude Code 程序路径（自动查找）", text: Binding(get: { store.settings.claudePath ?? "" }, set: { store.settings.claudePath = $0 }))
                Button("使用 Claude Console 登录") { store.signInAgent(.claude, console: true) }
              }.padding(.top, 8)
            }.padding(12)
          }
        }
      }
      if store.accountSigningIn != nil || store.chatgptSigningIn {
        HStack(alignment: .top) {
          ProgressView().controlSize(.small)
          VStack(alignment: .leading, spacing: 6) {
            Text(store.chatgptSigningIn ? store.chatgptLoginStatus : store.accountLoginStatus).font(.callout).textSelection(.enabled)
            if let url = store.accountLoginURL { Button("重新打开登录页面") { NSWorkspace.shared.open(url) } }
          }
          Spacer()
          Button("取消") { store.cancelAccountLogin(); store.chatgptLoginTask?.cancel() }
        }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
      } else if !store.accountLoginStatus.isEmpty { Text(store.accountLoginStatus).font(.callout).textSelection(.enabled) }
      if !store.chatgptSigningIn && store.chatgptLoginStatus != "可新增官方授权，或使用下方已保存的连接。" { Text(store.chatgptLoginStatus).font(.callout).textSelection(.enabled) }
    }.padding(16).tint(.gray)
      .sheet(item: $editing) { profile in SimpleAPIEditor(store: store, initial: profile) { editing = nil } }
      .onAppear { section = store.workspace; applyRequest() }
      .onChange(of: store.editingProfileID) { _, _ in applyRequest() }
      .onChange(of: store.apiSetupProvider) { _, _ in applyRequest() }
      .onChange(of: store.settings.cliPath) { _, _ in store.saveSoon() }
      .onChange(of: store.settings.claudePath) { _, _ in store.saveSoon() }
  }
  private func applyRequest() {
    store.addingConnection = false
    if let id = store.editingProfileID { editing = store.profiles.first { $0.id == id }; store.editingProfileID = nil }
    if let provider = store.apiSetupProvider { editing = provider.preset(); store.apiSetupProvider = nil }
  }
  private func providerRow(_ name: String, provider: ProviderKind, detail: String, action: String, perform: @escaping () -> Void) -> some View {
    HStack(spacing: 14) {
      Text(provider.monogram).font(.title3.bold()).frame(width: 36, height: 36).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 4) { Text(name).font(.headline).foregroundStyle(provider.accentColor); Text(detail).font(.caption).foregroundStyle(.secondary) }
      Spacer()
      Button(action, action: perform).disabled(store.isBusy || store.chatgptSigningIn)
    }.padding(13).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct SimpleAPIEditor: View {
  @ObservedObject var store: SessionStore
  let initial: APIProfile
  let close: () -> Void
  @State private var profile = APIProfile()
  @State private var key = ""
  @State private var notice = ""
  @State private var advanced = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("连接 " + initial.resolvedProvider.label).font(.title2.bold()); Spacer(); Button("取消", action: close) }
      Text("粘贴该服务的 API 密钥即可。用量由该服务单独计费。").font(.callout).foregroundStyle(.secondary)
      if let url = initial.resolvedProvider.apiKeyURL { Link("获取 API 密钥 ↗", destination: url) }
      SecureField(store.profiles.contains(where: { $0.id == profile.id }) ? "API 密钥（留空保留）" : "API 密钥", text: $key).textFieldStyle(.roundedBorder)
      TextField("模型名称（可留空自动获取）", text: $profile.defaultModel).textFieldStyle(.roundedBorder)
      DisclosureGroup("高级设置", isExpanded: $advanced) {
        VStack(spacing: 10) {
          TextField("连接名称", text: $profile.name)
          TextField("账号标签（多个账号时填写）", text: Binding(get: { profile.accountLabel ?? "" }, set: { profile.accountLabel = $0 }))
          TextField("接口地址", text: $profile.baseURL)
          Picker("协议", selection: $profile.format) { ForEach(APIFormat.allCases, id: \.rawValue) { Text($0.label).tag($0) } }
        }.textFieldStyle(.roundedBorder).padding(.top, 8)
      }
      if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      HStack { Spacer(); Button("连接") {
        do {
          let existing = store.profiles.contains { $0.id == profile.id }
          guard existing || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "请粘贴 API 密钥。"; return }
          try store.saveProfile(profile, key: key); key = ""
          store.switchConnection(.api(profile)); store.refreshAPIModels(profile); close()
        } catch { notice = error.localizedDescription }
      }.disabled(store.isBusy) }
    }.padding(24).frame(width: 480).onAppear { profile = initial; advanced = initial.resolvedProvider == .custom }
  }
}

extension ProviderKind {
  var apiKeyURL: URL? {
    let address: String
    switch self {
    case .openai: address = "https://platform.openai.com/api-keys"
    case .anthropic: address = "https://platform.claude.com/settings/keys"
    case .deepseek: address = "https://platform.deepseek.com/api_keys"
    case .kimi: address = "https://platform.moonshot.ai/console/api-keys"
    case .qwen: address = "https://bailian.console.aliyun.com/"
    case .gemini: address = "https://aistudio.google.com/api-keys"
    case .grok: address = "https://console.x.ai/"
    case .openrouter: address = "https://openrouter.ai/settings/keys"
    case .custom: return nil
    }
    return URL(string: address)
  }
}
