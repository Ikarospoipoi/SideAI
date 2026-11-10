import AppKit
import SideAICore
import SwiftUI

struct AttachmentStrip: View {
  var images: [ImageAttachment]
  var remove: ((ImageAttachment) -> Void)? = nil
  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(images) { attachment in
          VStack(spacing: 4) {
            AttachmentThumbnail(attachment: attachment, width: 76, height: 66)
            HStack(spacing: 3) {
              Text(attachment.name).lineLimit(1).font(.system(size: 9))
              if let remove {
                Button { remove(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                  .buttonStyle(.plain).help("移除图片").accessibilityLabel("移除图片")
              }
            }.frame(width: 82)
          }.padding(5).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }.frame(height: 100)
  }
}

struct ModelPicker: View {
  @ObservedObject var store: SessionStore
  @State private var search = ""
  @State private var manual = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("选择模型").font(.headline)
        Spacer()
        Button("刷新") {
          store.refreshCurrentModels()
        }
      }
      TextField("搜索模型", text: $search).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(store.availableModels.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { option in
            Button { store.selectModel(option) } label: {
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(option.name).font(.system(size: 12))
                  if option.name != option.id { Text(option.id).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                if store.selected?.modelID == option.id { Image(systemName: "checkmark") }
              }.padding(9).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }
      if let option = store.availableModels.first(where: { $0.id == store.selected?.modelID }), !option.efforts.isEmpty {
        Picker("推理强度", selection: Binding(get: { store.selected?.reasoningEffort ?? option.defaultEffort ?? "" }, set: { value in if let id = store.selectedID { store.mutate(id) { $0.reasoningEffort = value } } })) {
          ForEach(option.efforts, id: \.self) { Text($0).tag($0) }
        }
      }
      if store.selected?.engine == .api || store.selected?.engine == .claude || store.selected?.engine == .accountRuntime {
        Divider()
        Text(store.selected?.engine == .claude ? "Claude 显示官方模型别名，实际版本由 CLI 和账户决定；可输入完整模型 ID。" : "部分服务不提供模型列表，可手动输入模型 ID。").font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("模型 ID", text: $manual).textFieldStyle(.roundedBorder)
          Button("使用") { store.selectModel(ModelOption(id: manual.trimmingCharacters(in: .whitespacesAndNewlines))) }.disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(store.connectionNotice).font(.caption2).foregroundStyle(.secondary)
      }
      if let actual = store.selected?.resolvedModel { Text("上次实际模型：" + actual).font(.caption2).foregroundStyle(.secondary) }
      Text("选择会用于下一轮请求；可用模型与强度以服务商为准。").font(.caption2).foregroundStyle(.secondary)
    }.padding(16).frame(width: 320, height: 420)
      .onAppear { if store.availableModels.isEmpty { store.refreshCurrentModels() } }
  }
}

struct SettingsView: View {
  @ObservedObject var store: SessionStore
  @State private var tab = 0
  var body: some View {
    TabView(selection: $tab) {
      ConnectionManagerView(store: store, configure: { store.addingConnection = true; tab = 4 }).tabItem { Label("连接管理", systemImage: "network") }.tag(0)
      ConnectionsSettings(store: store).tabItem { Label("添加 AI", systemImage: "plus.circle") }.tag(4)
      HistorySettings(store: store).tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }.tag(1)
      MemorySettings(store: store).tabItem { Label("跨会话记忆", systemImage: "brain") }.tag(3)
      AppearanceSettingsView(store: store).tabItem { Label("侧栏与快捷键", systemImage: "sidebar.left") }.tag(2)
    }.padding(12).frame(width: 700, height: 740).tint(.gray)
      .onAppear { if store.addingConnection || store.apiSetupProvider != nil || store.editingProfileID != nil { tab = 4 } }
      .onChange(of: store.apiSetupProvider) { _, value in if value != nil { tab = 4 } }
      .onChange(of: store.settingsRequest) { _, _ in tab = store.addingConnection || store.apiSetupProvider != nil || store.editingProfileID != nil ? 4 : 0 }
  }
}

struct MemorySettings: View {
  @ObservedObject var store: SessionStore
  @State private var search = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("跨会话记忆").font(.title3.bold())
      Toggle("新会话自动查找相关历史", isOn: Binding(get: { store.settings.crossConversationMemory != false }, set: { store.settings.crossConversationMemory = $0; store.saveSoon() })).disabled(store.isBusy)
      Text("聊天与 Agent 共用本地历史，包含导入的记录。每次发送只带相关摘录和下方笔记，交给当前连接的服务商。可在输入框上方查看来源；各家官网内部记忆不会自动同步。").font(.callout).foregroundStyle(.secondary)
      Text("记忆笔记：长期偏好、项目背景或重要结论").font(.headline)
      TextEditor(text: Binding(get: { store.settings.sharedMemory ?? "" }, set: { store.settings.sharedMemory = $0; store.saveSoon() }))
        .font(.body).frame(height: 100).border(.primary.opacity(0.15))
      Text("开启记忆时自动携带前 2,000 字。旧任务不构成执行授权，Agent 仍按当前权限审批。").font(.caption).foregroundStyle(.secondary)
      TextField("查找会话，设置是否参与记忆", text: $search).textFieldStyle(.roundedBorder)
      ScrollView { LazyVStack(alignment: .leading) {
        ForEach(store.state.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted { $0.updatedAt > $1.updatedAt }) { c in
          Toggle(c.title, isOn: Binding(get: { c.memoryExcluded != true }, set: { value in store.mutate(c.id) { $0.memoryExcluded = !value } })).disabled(store.isBusy)
        }
      } }
    }.padding(20)
  }
}

struct HistorySettings: View {
  @ObservedObject var store: SessionStore
  var body: some View {
    Form {
      Section("Codex 会话同步") {
        Text("读取本机 App Server 可见的所有来源与归档会话，按 thread ID 去重。打开历史时只读取；发送消息时才恢复执行连接。").font(.callout)
        Button(store.syncing ? "正在同步…" : "同步所有可见 Codex 会话") { store.syncConversations() }.disabled(store.syncing || !store.ready || store.isBusy)
        Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
      }
      Section("ChatGPT 历史") {
        Text("本机 App Server 当前不提供普通 ChatGPT 网页聊天列表。可从 ChatGPT 设置导出数据，解压后导入 conversations.json；导入当前分支的文字，附件文件不会包含在此 JSON 中。").font(.callout)
        Button("导入 ChatGPT conversations.json…") { store.importChatGPT() }
        Text("导入先保存为只读记录。选择“通过默认 API 连接继续此会话”会建立副本，直到你发送新消息时才提交该副本的上下文。此功能不提供 ChatGPT 云端双向同步。").font(.caption).foregroundStyle(.secondary)
      }
      Section("本地数据") {
        Text("会话、草稿和图片缓存在本机 Application Support/SideAI。顶部连接菜单切换独立空间；会话列表默认只显示当前连接，也可查看全部连接。").font(.caption)
        Button("打开本地数据文件夹") { NSWorkspace.shared.open(store.persistence.directory) }
      }
    }.formStyle(.grouped)
  }
}

struct AttachmentThumbnail: View {
  let attachment: ImageAttachment
  let width: CGFloat
  let height: CGFloat
  @State private var image: NSImage?
  var body: some View {
    Group {
      if let image { Image(nsImage: image).resizable().scaledToFit() }
      else { Image(systemName: "photo") }
    }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 6))
      .task(id: attachment.path) { image = NSImage(contentsOfFile: attachment.path) }
      .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) }
  }
}

struct ConnectionSwitcher: View {
  @ObservedObject var store: SessionStore
  var afterSelection: (() -> Void)? = nil
  var body: some View {
    Menu {
      ForEach(store.workspaceRoutes) { route in
        Button {
          store.switchConnection(route); afterSelection?()
        } label: {
          Text((route.id == store.currentRoute.id ? "✓ " : "") + route.name + (store.isRouteActive(route) ? "" : " · 切换并启用"))
        }
      }
    } label: {
      HStack(spacing: 4) { Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary); Text(store.currentRoute.name).foregroundStyle(store.currentRoute.provider.accentColor) }.font(.system(size: 12, weight: .semibold)).lineLimit(1)
    }.menuStyle(.borderlessButton).tint(.gray).fixedSize(horizontal: false, vertical: true).help("切换连接 · 各连接的历史和草稿互相独立").accessibilityLabel("切换连接")
  }
}
