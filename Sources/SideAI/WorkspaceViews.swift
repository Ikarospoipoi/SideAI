import AppKit
import SideAICore
import SwiftUI

struct WorkspaceSwitcher: View {
  @ObservedObject var store: SessionStore
  var body: some View {
    Picker("模式", selection: Binding(get: { store.workspace }, set: {
      store.switchWorkspace($0)
      if $0 == .agent {
        if store.selected?.engine == .codex && !store.ready { store.connect() }
      }
      if store.selected?.engine == .claude && store.isRouteActive(store.currentRoute) { store.refreshClaudeStatus() }
    })) {
      ForEach(WorkspaceMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("聊天与 Agent 模式")
  }
}
struct LauncherView: View {
  @ObservedObject var store: SessionStore
  var configure: (ProviderKind?) -> Void
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("SideAI").font(.system(size: 21, weight: .semibold))
          Text(store.workspace == .chat ? "轻量聊天，连接你的模型" : "选择 Agent，开始处理任务").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { configure(nil) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("连接设置").accessibilityLabel("连接设置")
      }
      WorkspaceSwitcher(store: store)
      if store.workspaceRoutes.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(.secondary)
          Text(store.workspace == .chat ? "添加第一个 AI" : "添加第一个 Agent").font(.headline)
          Text("选择你常用的服务，登录后就能开始。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
      } else {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
          ForEach(store.workspaceRoutes) { route in
            Button { store.switchConnection(route) } label: {
              tile(name: route.name, symbol: route.provider.monogram, detail: "进入对话", color: route.provider.accentColor, configured: true)
            }.buttonStyle(.plain).accessibilityLabel(route.name + "，进入对话")
          }
        }
      }
      Button {
        store.addingConnection = true
        configure(nil)
      } label: { Label(store.workspace == .chat ? "添加 AI" : "添加 Agent", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
        .buttonStyle(.bordered)
      Spacer(minLength: 0)
      Text(store.workspace == .chat ? "不执行本机工具 · 发送前可交给 Agent" : "运行中任务收起后继续 · 可随时停止")
        .font(.system(size: 10)).foregroundStyle(.secondary)
      if store.approvalCount > 0 { Text("\(store.approvalCount) 项任务等待确认").font(.caption).foregroundStyle(.orange) }
    }.padding(20).tint(.gray)
    }
  }
  private func tile(name: String, symbol: String, detail: String, color: Color, configured: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(symbol).font(.system(size: 18, weight: .semibold, design: .rounded))
          .frame(width: 30, height: 30).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        Spacer()
        Image(systemName: configured ? "arrow.up.right" : "plus").font(.system(size: 10, weight: .semibold))
      }.foregroundStyle(.secondary)
      Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
      Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).frame(height: 27, alignment: .topLeading)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)))
      .contentShape(RoundedRectangle(cornerRadius: 12))
  }
}

struct HandoffView: View {
  @ObservedObject var store: SessionStore
  let source: Conversation
  let dismiss: () -> Void
  @State private var targetID = ConnectionRoute.codex.id
  @State private var task = ""
  @State private var context = ""
  @State private var includeMemory = false
  @State private var selectedImages = Set<UUID>()
  @State private var project = ""
  @State private var mode = AgentMode.readOnly
  private var target: ConnectionRoute { store.routes.first { $0.id == targetID } ?? .codex }
  private var images: [ImageAttachment] {
    var seen = Set<UUID>()
    return (source.items.flatMap { $0.attachments ?? [] } + source.images).filter { seen.insert($0.id).inserted }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text("交给 Agent").font(.title3.bold()); Spacer(); Button("取消", action: dismiss) }
      Text("将创建独立任务草稿；点击发送后，以下内容才会交给 \(target.name)。原会话保留。").font(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Picker("目标 Agent", selection: $targetID) {
            ForEach(store.routes.filter { $0.workspace == .agent }) { Text($0.name).tag($0.id) }
          }
          Text("任务要求").font(.headline)
          TextEditor(text: $task).frame(height: 70).border(.primary.opacity(0.15))
          HStack {
            Text("携带的对话背景（可编辑）").font(.headline)
            Spacer()
            Button("载入最近 6 条") {
              let items = source.items.filter { ["userMessage", "agentMessage"].contains($0.kind) && $0.status == "completed" }.suffix(6)
              context = HandoffBuilder.transcript(source, ids: Set(items.map(\.id)))
            }
            Button("清空") { context = "" }
          }
          TextEditor(text: $context).frame(height: 140).border(.primary.opacity(0.15))
          Text("默认不携带历史；可载入最近消息，或自行填写摘要。工具记录和隐藏推理不会复制。").font(.caption).foregroundStyle(.secondary)
          if !images.isEmpty {
            Text("携带图片").font(.headline)
            ForEach(images) { image in
              Toggle(image.name, isOn: Binding(get: { selectedImages.contains(image.id) }, set: { if $0 { selectedImages.insert(image.id) } else { selectedImages.remove(image.id) } }))
            }
          }
          Toggle("携带我的记忆笔记", isOn: $includeMemory).disabled((store.settings.sharedMemory ?? "").isEmpty)
          if includeMemory { Text(store.settings.sharedMemory ?? "").font(.caption).textSelection(.enabled) }
          Picker("权限", selection: $mode) { ForEach(AgentMode.allCases, id: \.rawValue) { Text($0.label).tag($0) } }
          HStack {
            Text(project.isEmpty ? "未选择项目" : project).font(.caption).lineLimit(2)
            Spacer()
            Button("选择项目…") {
              let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
              if panel.runModal() == .OK, let url = panel.url { project = url.path }
            }
          }
          Text("不会复制原 Agent 的执行状态或权限。新任务使用这里选择的项目和权限。").font(.caption).foregroundStyle(.secondary)
        }.padding(2)
      }
      HStack {
        Spacer()
        Button("创建任务草稿") {
          store.createHandoff(source: source, route: target, task: task, context: context,
                              images: images.filter { selectedImages.contains($0.id) },
                              memory: includeMemory ? store.settings.sharedMemory ?? "" : "", cwd: project, mode: mode)
          dismiss()
        }.disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .project && project.isEmpty) || store.isBusy || !store.routes.contains(where: { $0.id == targetID }))
      }
    }.padding(20).frame(width: 480, height: 620).background(Color(nsColor: .windowBackgroundColor)).tint(.gray)
      .onAppear { task = source.draft; targetID = store.routes.first(where: { $0.workspace == .agent })?.id ?? "" }
  }
}

struct ClaudeApprovalCard: View {
  @ObservedObject var store: SessionStore
  let request: ClaudeApproval
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Claude Code 请求：" + request.tool).font(.headline)
      Text(request.cwd).font(.caption).foregroundStyle(.secondary)
      ScrollView { Text(request.input.pretty).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
      HStack { Button("拒绝") { reply(false) }; Spacer(); Button("仅批准这一次") { reply(true) } }
    }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }
  private func reply(_ allow: Bool) {
    guard store.claudeApprovals.contains(where: { $0.id == request.id }), let client = store.claudeClients[request.conversationID] else { return }
    client.sendControl(ClaudePermissions.reply(id: request.id, input: request.input, allow: allow))
    store.claudeApprovals.removeAll { $0.id == request.id }
    store.mutate(request.conversationID) { $0.status = .running }
  }
}
