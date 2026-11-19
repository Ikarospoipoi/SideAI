import AppKit
import SideAICore
import SwiftUI

struct ProductivityView: View {
  @ObservedObject var store: SessionStore
  var dismiss: () -> Void
  @State private var tab = 0
  private let tabs = [("全文搜索", "magnifyingglass"), ("上下文", "brain"), ("项目", "folder"), ("任务", "list.bullet"), ("文本与文件", "doc.text"), ("各端能力", "desktopcomputer")]
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text("工作台").font(.title2.bold()); Spacer(); Button("关闭", action: dismiss) }
      HStack(spacing: 4) {
        ForEach(tabs.indices, id: \.self) { index in
          Button { tab = index } label: { Label(tabs[index].0, systemImage: tabs[index].1).font(.caption).padding(.vertical, 9).frame(maxWidth: .infinity) }
            .buttonStyle(.plain).background(tab == index ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      Divider()
      Group {
        switch tab {
        case 0: HistorySearchView(store: store, dismiss: dismiss)
        case 1: ContextSettingsView(store: store)
        case 2: ProjectWorkbenchView(store: store)
        case 3: TaskCenterView(store: store)
        case 4: QuickTextView(store: store, dismiss: dismiss)
        default: CapabilityView()
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.padding(18).frame(width: 680, height: 600)
  }
}
struct HistorySearchView: View {
  @ObservedObject var store: SessionStore
  var dismiss: () -> Void
  @State private var query = ""
  @State private var projectOnly = false
  @State private var hits: [HistoryHit] = []
  @State private var searching = false
  var body: some View {
    VStack(alignment: .leading) {
      TextField("搜索标题和消息正文；空格分隔多个关键词", text: $query).textFieldStyle(.roundedBorder)
      Toggle("仅当前项目", isOn: $projectOnly)
      Text("搜索本机可见文本，含归档；不会查询 AI 或自动同步历史。最多显示 100 处匹配。").font(.caption).foregroundStyle(.secondary)
      if searching { ProgressView() }
      List(hits) { hit in
        Button { store.openSearchResult(hit); dismiss() } label: {
          VStack(alignment: .leading, spacing: 5) { Text(hit.title).bold(); Text(hit.excerpt).font(.caption).lineLimit(4) }
        }.buttonStyle(.plain)
      }
      if !query.isEmpty && hits.isEmpty && !searching { Text("未找到匹配内容").foregroundStyle(.secondary) }
    }.padding().task(id: query + ":" + String(projectOnly)) {
      searching = true
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
      let history = store.state.conversations.filter { store.searchable($0) && (!projectOnly || ProjectHistory.path($0.cwd) == store.selected.map { ProjectHistory.path($0.cwd) }) }
      let search = query
      let result = await Task.detached(priority: .userInitiated) { HistorySearch.search(search, conversations: history) }.value
      guard !Task.isCancelled else { return }
      hits = result; searching = false
    }
  }
}
struct ContextSettingsView: View {
  @ObservedObject var store: SessionStore
  var body: some View {
    ScrollView {
      if let c = store.selected, store.enhanced(c) {
        let p = store.preferences(for: c)
        VStack(alignment: .leading, spacing: 12) {
          Text("历史参考范围").font(.headline)
          Picker("范围", selection: Binding(get: { p.scope }, set: { value in store.updatePreferences(c.id) { $0.scope = value } })) {
            ForEach(HistoryScope.allCases, id: \.rawValue) { Text($0.label).tag($0) }
          }.pickerStyle(.segmented)
          Text("当前目录：\(c.cwd)").font(.caption).textSelection(.enabled)
          Button("选择项目目录…") { store.chooseConversationProject() }
          if p.scope == .selected {
            ForEach(store.state.conversations.filter { $0.id != c.id && $0.memoryExcluded != true }) { source in
              Toggle(source.title, isOn: Binding(get: { p.sourceIDs.contains(source.id) }, set: { value in
                store.updatePreferences(c.id) { $0.sourceIDs.removeAll { $0 == source.id }; if value { $0.sourceIDs.append(source.id) } }
              }))
            }
          }
          Text("固定记忆（开启记忆时优先携带前 2,000 字）").font(.headline)
          TextEditor(text: Binding(get: { p.pinnedNotes }, set: { value in store.updatePreferences(c.id) { $0.pinnedNotes = value } })).frame(height: 70).border(.secondary.opacity(0.3))
          if [.api, .accountRuntime].contains(c.engine) {
            Picker("输入上下文预算（估算 tokens）", selection: Binding(get: { p.contextBudget }, set: { value in store.updatePreferences(c.id) { $0.contextBudget = value } })) {
              ForEach([4000, 8000, 16000, 32000, 64000], id: \.self) { Text(String($0)).tag($0) }
            }
            Text("固定摘要：填写已经核对的重要事实；随每轮上下文发送").font(.headline)
            TextEditor(text: Binding(get: { p.summary }, set: { value in store.updatePreferences(c.id) { $0.summary = value } })).frame(height: 90).border(.secondary.opacity(0.3))
          }
          Text(store.contextPreview(c)).font(.caption).foregroundStyle(.secondary)
          Text("预算不是服务商精确 token 数，也不是金额估算。旧消息只从本次请求中省略；记忆检索另有用量。原始历史与图片不会被删除。").font(.caption).foregroundStyle(.secondary)
        }.disabled(c.status.isActive).padding()
      }
    }
  }
}
struct ContextBudgetIndicator: View {
  @ObservedObject var store: SessionStore
  let conversation: Conversation
  @State private var text = "正在估算上下文…"
  private var revision: String {
    let p = store.preferences(for: conversation)
    return "\(conversation.id):\(conversation.draft.hashValue):\(conversation.items.count):\(conversation.items.last?.status ?? ""):\(conversation.images.count):\(p.contextBudget):\(p.summary.hashValue)"
  }
  var body: some View {
    Text(text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).task(id: revision) {
      do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
      var items = conversation.items
      var next = TimelineItem(kind: "userMessage", text: conversation.draft); next.attachments = conversation.images; items.append(next)
      let history = items, preferences = store.preferences(for: conversation)
      let result = await Task.detached(priority: .utility) {
        do {
          let plan = try ContextPlanner.plan(history, preferences: preferences, reserve: 1024)
          return "约 \(plan.estimatedTokens) tokens · 本轮省略 \(plan.omitted) 条旧消息 · 原记录保留"
        } catch { return error.localizedDescription }
      }.value
      if !Task.isCancelled { text = result }
    }
  }
}
struct ProjectWorkbenchView: View {
  @ObservedObject var store: SessionStore
  @State private var name = ""
  @State private var prompt = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let c = store.selected {
        Text(c.cwd).font(.caption).textSelection(.enabled)
        Button("选择目录…") { store.chooseConversationProject() }.disabled(store.isBusy)
        TextField("项目名称", text: $name).textFieldStyle(.roundedBorder)
        Text("常用提示词（打开项目时填入新草稿，不自动发送）").font(.caption)
        TextEditor(text: $prompt).frame(height: 90).border(.secondary.opacity(0.3))
        Button("保存当前连接、模型、记忆范围与提示词") { store.saveProject(c, name: name, prompt: prompt) }.disabled(store.isBusy)
      }
      List(store.productivitySettings.projects) { project in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
          VStack(alignment: .leading) { Text(project.name); Text(project.id).font(.caption).foregroundStyle(.secondary) }
          Spacer(); Button("打开") { store.openProject(project) }.disabled(store.isBusy)
          Button("移除") { var settings = store.productivitySettings; settings.projects.removeAll { $0.id == project.id }; store.settings.productivity = settings; store.saveSoon() }
          }
          ForEach(Array(store.state.conversations.filter { store.enhanced($0) && ProjectHistory.path($0.cwd) == project.id && !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))) { c in
            Button { store.select(c.id) } label: { Text(c.title + " · " + c.status.label).font(.caption).foregroundStyle(.secondary) }.buttonStyle(.plain)
          }
        }
      }
    }.padding().onAppear { loadProject() }.onChange(of: store.selectedID) { _, _ in loadProject() }
  }
  private func loadProject() {
    let project = store.selected.flatMap { c in store.productivitySettings.projects.first { $0.id == ProjectHistory.path(c.cwd) } }
    name = project?.name ?? ""; prompt = project?.prompt ?? ""
  }
}
struct TaskCenterView: View {
  @ObservedObject var store: SessionStore
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button("将当前草稿加入队列") { store.enqueueSelected() }.disabled(store.selected?.canSendContent != true || store.selected?.status.isActive == true)
        Button(store.queueRunning ? "暂停后续任务" : "开始队列") { store.queueRunning ? store.pauseQueue() : store.startQueue() }.disabled(!store.queueRunning && store.productivitySettings.queue.isEmpty)
      }
      Text("串行执行。排队会建立独立会话；失败或停止后暂停剩余任务。重启后不会自动发送，暂停队列不打断当前任务。").font(.caption).foregroundStyle(.secondary)
      Toggle("桌面完成、失败与审批通知", isOn: Binding(get: { store.productivitySettings.notifications }, set: { store.productivityCoordinator.setNotifications($0) }))
      List {
        Section("待执行") {
          ForEach(store.productivitySettings.queue) { job in
            if let c = store.state.conversations.first(where: { $0.id == job.id }) {
              VStack(alignment: .leading) {
                HStack { Button(c.title) { store.select(c.id) }; Spacer(); Button("取消排队") { store.removeQueued(job.id) } }
                Text(store.route(for: c).name + " · " + (c.modelID ?? "默认模型") + " · " + c.cwd).font(.caption).foregroundStyle(.secondary)
              }
            } else { Button("移除不存在的任务") { store.removeQueued(job.id) } }
          }
        }
        Section("最近任务") {
          ForEach(Array(store.state.conversations.filter { store.enhanced($0) && $0.status != .idle }.sorted { $0.updatedAt > $1.updatedAt }.prefix(60))) { c in
            HStack { Button(c.title) { store.select(c.id) }; Spacer(); Text(c.status.label).foregroundStyle(c.status == .failed ? .orange : .secondary)
              if c.status.isActive { Button("停止") { store.interrupt(c.id) } }
            }
          }
        }
      }
    }.padding()
  }
}
struct QuickTextView: View {
  @ObservedObject var store: SessionStore
  var dismiss: () -> Void
  @State private var text = ""
  @State private var instruction = "请翻译为中文，保留原意与格式。"
  @State private var notice = ""
  @State private var reading = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button("从剪贴板读取") { text = NSPasteboard.general.string(forType: .string) ?? "" }
        Button("读取文本／代码／日志／PDF…") {
          let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
          if panel.runModal() == .OK, let url = panel.url {
            reading = true
            Task {
              defer { reading = false }
              do { text = try await Task.detached(priority: .userInitiated) { try DocumentAttachment.read(url) }.value; notice = "已读取 \(url.lastPathComponent)，请先检查内容。" }
              catch { notice = error.localizedDescription }
            }
          }
        }
      }
      if reading { ProgressView("正在读取文件…") }
      Picker("操作", selection: $instruction) {
        Text("翻译").tag("请翻译为中文，保留原意与格式。")
        Text("解释").tag("请解释以下内容，并指出关键点。")
        Text("润色").tag("请润色以下文字，保留原意，不添加未经提供的事实。")
        Text("分析报错").tag("请分析以下错误，给出原因、排查步骤与修复建议。")
        Text("总结").tag("请总结以下内容，列出关键结论与待办。")
      }
      TextEditor(text: $text).font(.system(.body, design: .monospaced)).border(.secondary.opacity(0.3))
      Text(notice.isEmpty ? "主动读取后预览；加入草稿不发送，也不会监控剪贴板。" : notice).font(.caption).foregroundStyle(.secondary)
      Button("加入当前草稿") { store.appendQuickText(text, instruction: instruction); dismiss() }.disabled(reading || text.isEmpty || store.selected?.status.isActive == true)
    }.padding()
  }
}
struct CapabilityView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("能力按客户端区分").font(.headline)
      Text("macOS：全文搜索、项目与上下文设置、任务队列、快捷文本、会话分支与导出。")
      Text("Windows：聊天、Agent、图片、全文搜索、按需历史工具、上下文预算、快捷文本、会话分支与导出。项目配置与队列目前在 Mac 提供。")
      Text("iPhone：遥控 Mac 的会话、模型和审批，支持会话搜索与更早历史分页。电脑执行任务；手机后台可能断开连接，当前没有后台推送。")
      Text("三端不自动同步账号；手机配对连接电脑，Windows 暂不作为遥控主机。").font(.caption).foregroundStyle(.secondary)
      Spacer()
    }.padding()
  }
}
enum TextAttachment {
  static func read(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 1_000_000 else { throw ProtocolError.message("请选择不超过 1 MB 的文本文件。") }
    let data = try Data(contentsOf: url)
    guard data.count <= 1_000_000, !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ProtocolError.message("仅支持 UTF-8 文本、代码或日志；二进制文件不会发送。") }
    return "文件：\(url.lastPathComponent)\n\n" + text
  }
}
