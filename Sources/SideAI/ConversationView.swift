import AppKit
import SideAICore
import SwiftUI

struct PanelSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) var reduceTransparency
  func body(content: Content) -> some View {
    content.background {
      if reduceTransparency {
        Color(nsColor: .windowBackgroundColor)
      } else {
        ZStack {
          Rectangle().fill(.regularMaterial)
          Color(nsColor: .windowBackgroundColor).opacity(0.85)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 18)).overlay(
      RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.12), lineWidth: 1))
  }
}
struct HandleView: View {
  private var accent: Color { .secondary }
  @ObservedObject var store: SessionStore
  var open: () -> Void
  var body: some View {
    Button(action: open) {
      Capsule().fill(
        store.approvalCount == 0
          ? (store.activeCount > 0 ? accent : Color.secondary.opacity(0.7)) : .orange
      )
      .overlay { if store.approvalCount > 0 { Circle().fill(.white).frame(width: 4, height: 4) } }
      .padding(.vertical, 6).padding(.horizontal, 1)
    }.buttonStyle(.plain).help(store.approvalCount == 0 ? "展开 SideAI" : "\(store.approvalCount) 项等待确认")
      .accessibilityLabel("展开 SideAI，\(store.approvalCount) 项等待确认")
  }
}
struct PeekView: View {
  @ObservedObject var store: SessionStore
  var configure: (ProviderKind?) -> Void
  var body: some View {
    LauncherView(store: store, configure: configure)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).modifier(PanelSurface())
  }
}
struct ConversationView: View {
  private var accent: Color { .secondary }
  @ObservedObject var store: SessionStore
  let controller: EdgePanelController
  @State private var showSessions = false
  @State private var showModels = false
  @State private var showHandoff = false
  @State private var resizeStart: CGFloat?
  var body: some View {
    VStack(spacing: 0) {
      Capsule().fill(accent.opacity(0.5)).frame(width: 34, height: 4)
        .frame(maxWidth: .infinity).frame(height: 20)
        .overlay(WindowDragArea(finished: controller.didDragWindow))
      if store.selected == nil {
        LauncherView(store: store) { provider in store.apiSetupProvider = provider; controller.showSettings?() }
      } else {
      header
      Divider().opacity(0.5)
      if let error = store.hotkeyError { notice(error, symbol: "keyboard") }
      if let banner = store.banner {
        HStack(alignment: .top) {
          notice(banner, symbol: "exclamationmark.circle")
          Button {
            store.banner = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).padding(12)
        }
      }
      if !store.isRouteActive(store.currentRoute) && store.selected?.engine != .chatgptArchive {
        HStack { Text("此通道已停用，历史和草稿仍保留。").font(.caption); Spacer(); Button("启用此连接") { _ = store.activate(store.currentRoute) } }.padding(12)
      }
      if !store.ready && store.selected?.engine == .codex { connectionCard }
      if store.selected?.engine == .claude && !store.claudeReady {
        HStack { Text(store.claudeStatus).font(.caption); Spacer(); Button("检测登录") { store.refreshClaudeStatus() }; Button("设置") { controller.showSettings?() } }.padding(12)
      }
      ForEach(store.claudeApprovals.filter { $0.conversationID == store.selectedID }) { request in
        ClaudeApprovalCard(store: store, request: request).padding(8)
      }
      if let approval = store.claudeApprovals.first(where: { $0.conversationID != store.selectedID }) {
        Button("Claude Code 有任务等待确认") { store.select(approval.conversationID) }.padding(8)
      }
      if !store.selectedPending.isEmpty {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(store.selectedPending) { request in ApprovalCard(store: store, request: request)
            }
          }.padding(12)
        }.frame(maxHeight: 300)
        Divider()
      } else if !store.pending.isEmpty {
        Button {
          if let p = store.pending.first,
            let c = store.state.conversations.first(where: { $0.threadID == p.threadID })
          {
            store.select(c.id)
          }
        } label: {
          Label("其他会话有 \(store.pending.count) 项待确认", systemImage: "hand.raised.fill").frame(
            maxWidth: .infinity
          ).padding(10)
        }.buttonStyle(.plain).foregroundStyle(.orange)
      }
      if let c = store.selected { TimelineView(conversation: c).id(c.id) } else { Spacer() }
      composer
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .modifier(PanelSurface())
    .environment(\.providerAccent, .secondary)
    .overlay(alignment: .trailing) {
      Rectangle().fill(.clear).frame(width: 6).contentShape(Rectangle())
        .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .gesture(
          DragGesture().onChanged { value in
            if resizeStart == nil { resizeStart = store.settings.panelWidth }
            controller.resize(by: value.translation.width, start: resizeStart ?? 460)
          }.onEnded { _ in resizeStart = nil })
    }
    .tint(.gray)
    .sheet(isPresented: $showHandoff) {
      if let c = store.selected { HandoffView(store: store, source: c, dismiss: { showHandoff = false }) }
    }
    .onChange(of: showModels) { _, _ in store.hasPopover = showModels || showSessions }
    .onChange(of: showSessions) { _, _ in store.hasPopover = showModels || showSessions }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SideAIDismissPopovers"))) { _ in
      showModels = false; showSessions = false; store.hasPopover = false
    }
  }
  private var header: some View {
    VStack(spacing: 10) {
    WorkspaceSwitcher(store: store).frame(maxWidth: 220)
    HStack(spacing: 10) {
      Button {
        showSessions.toggle()
      } label: {
        Image(systemName: "sidebar.left").font(.system(size: 17))
      }.help("切换会话").accessibilityLabel("切换会话")
        .popover(isPresented: $showSessions, arrowEdge: .bottom) {
          SessionPicker(store: store, dismiss: { showSessions = false })
        }
      VStack(alignment: .leading, spacing: 3) {
        ConnectionSwitcher(store: store)
        Text(store.selected?.title ?? "SideAI").font(.system(size: 12, weight: .medium))
          .lineLimit(1)
        HStack(spacing: 5) {
          Circle().fill(store.currentConnectionReady ? accent : .orange).frame(width: 5, height: 5)
          Text(store.selected?.status.label ?? store.connection).font(.system(size: 10))
          if store.activeCount > 0 { Text("· 收起后继续").font(.system(size: 10)) }
        }.foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Menu {
        Button("在当前连接新建会话") { store.newConversation() }
        Divider()
        ForEach(store.workspaceRoutes) { route in Button(route.name) { store.newConversation(route: route) } }
      } label: { Image(systemName: "square.and.pencil") }
      .menuStyle(.borderlessButton).fixedSize().help("新建会话").accessibilityLabel("新建会话")
      Button {
        controller.pin()
      } label: {
        Image(systemName: store.panelState == .pinned ? "pin.fill" : "pin")
      }.help("固定侧栏").accessibilityLabel("固定侧栏")
      Menu {
        Button("选择 AI…") {
          controller.collapse(restoreFocus: false)
          controller.showPeek(persistent: true)
        }
        Button("窗口回到屏幕左侧") { controller.resetPosition() }
        Button("设置…") { controller.showSettings?() }
        Button("检查当前连接") { if store.selected?.engine == .codex { store.connect() } else { store.refreshCurrentModels() } }.disabled(store.isBusy)
        Divider()
        Button("退出 SideAI") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).fixedSize().help("更多")
      Button {
        controller.collapse(restoreFocus: true)
      } label: {
        Image(systemName: "chevron.left")
      }.help("收起 · Esc").accessibilityLabel("收起侧栏")
    }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.8)).padding(.horizontal, 18).padding(
      .vertical, 6)
      if let c = store.selected {
        HStack(spacing: 12) {
          Button(c.workspace == .chat ? "交给 Agent…" : "交给其他 Agent…") { showHandoff = true }.disabled(store.isBusy)
          if let link = c.handoff, store.state.conversations.contains(where: { $0.id == link.sourceID }) {
            Button("原会话") { store.select(link.sourceID) }.help(link.sourceTitle)
            Button("带回结果") { store.bringResultBack() }.disabled(!c.items.contains { $0.kind == "agentMessage" && $0.status == "completed" })
          }
          let children = store.state.conversations.filter { $0.handoff?.sourceID == c.id }
          if !children.isEmpty {
            Menu("关联任务 (\(children.count))") { ForEach(children) { child in Button(child.title) { store.select(child.id) } } }.menuStyle(.borderlessButton).fixedSize()
          }
          Spacer(minLength: 0)
        }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
      }
    }
  }
  private func notice(_ text: String, symbol: String) -> some View {
    Label(text, systemImage: symbol).font(.caption).foregroundStyle(.orange).frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(12).textSelection(.enabled)
  }
  private var connectionCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(store.connection).font(.headline)
      Text("通过本机 Codex 连接。AI 请求会使用所配置账户的额度。").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(store.connecting ? "正在连接…" : "连接 / 重试") { store.connect() }.disabled(
          store.connecting)
        if store.connection == "需要登录" { Button("使用 ChatGPT 登录") { store.login() } }
        Button("设置") { controller.showSettings?() }
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.06))
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if store.selected?.engine == .chatgptArchive {
        Text("ChatGPT 导入记录 · 只读").font(.caption).foregroundStyle(.secondary)
        Button("通过默认 API 连接继续此会话") { store.continueArchive() }
      } else {
      if store.selected?.engine == .claude && store.selected?.claudeAgentEnabled != true && store.selected?.claudeChatOnly != true {
        Text("旧会话保留无工具模式。点击“交给其他 Agent”可创建新的执行任务。").font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 7) {
        if store.selected?.workspace == .agent {
        Menu {
          ForEach(AgentMode.allCases, id: \.rawValue) { mode in
            Button(mode.label) {
              if let c = store.selected { store.mutate(c.id) { $0.mode = mode } }
            }
          }
        } label: {
          Label(store.selected?.mode.label ?? "只读 Agent", systemImage: "shield.lefthalf.filled")
            .font(.caption)
        }.menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy)
        Spacer()
        Button {
          store.chooseProject()
        } label: {
          Label(
            store.selected?.cwd == store.scratch.path
              ? "选择项目" : URL(fileURLWithPath: store.selected?.cwd ?? "").lastPathComponent,
            systemImage: "folder"
          ).lineLimit(1).font(.caption)
        }.buttonStyle(.plain).help(store.selected?.cwd ?? "").disabled(
          store.isBusy)
        } else {
          Label("轻量聊天 · 不执行本机工具", systemImage: "bubble.left.and.bubble.right").font(.caption)
          Spacer()
          Button("连接设置") { controller.showSettings?() }.buttonStyle(.plain).font(.caption)
        }
      }.foregroundStyle(.secondary)
      MemoryIndicator(store: store)
      if let c = store.selected, !c.images.isEmpty {
        AttachmentStrip(images: c.images) { image in
          store.mutate(c.id) { $0.attachments = $0.images.filter { $0.id != image.id } }
        }
      }
      VStack(spacing: 0) {
        ComposerEditor(
          text: Binding(
            get: { store.selected?.draft ?? "" },
            set: { value in if let id = store.selectedID { store.mutate(id) { $0.draft = value } } }
          ), send: store.send,
          imageFiles: { [id = store.selectedID] urls in if let id { store.addImageURLs(urls, to: id) } },
          imageData: { [id = store.selectedID] data in if let id { store.addImageData(data, to: id) } }
        ).id(store.selectedID)
        .frame(height: 78).padding(.horizontal, 6).padding(.top, 8)
        HStack {
          Button { store.chooseImages() } label: { Image(systemName: "photo.badge.plus") }
            .buttonStyle(.plain).help("添加图片（也可粘贴或拖入）").accessibilityLabel("添加图片")
          Text("↵ 发送 · ⇧ ↵ 换行").font(.system(size: 10)).foregroundStyle(.tertiary)
          Spacer()
          if store.selected?.status.isActive == true {
            Button {
              store.interrupt()
            } label: {
              Image(systemName: "stop.fill").font(.system(size: 11, weight: .semibold)).frame(
                width: 28, height: 28)
            }.buttonStyle(.bordered).help("停止当前任务").disabled(store.selected?.engine == .codex && store.selected?.turnID == nil)
          } else {
            Button {
              store.send()
            } label: {
              Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(
                width: 28, height: 28)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.circle).help("发送消息")
              .accessibilityLabel("发送消息").disabled(
                !store.canSend
              )
          }
        }.padding(.horizontal, 12).padding(.bottom, 10)
      }.background(Color(nsColor: .textBackgroundColor).opacity(0.7)).clipShape(
        RoundedRectangle(cornerRadius: 13)
      ).overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.1)))
      HStack {
        Text(store.selected?.engine == .claude ? (store.selected?.claudeChatOnly == true ? "官方 Claude Code 账号 · 纯聊天 · 工具已关闭" : store.selected?.claudeAgentEnabled == true ? "Claude Code · 文件工具 · 写入需确认" : "旧 Claude Code 会话 · 工具已关闭") : store.selected?.workspace == .chat ? "轻量聊天 · 独立会话" : store.selected?.mode == .project ? "项目内可修改 · 越界需审批" : "只读 · 写入需审批").font(.system(size: 10))
        Spacer()
        Button { showModels.toggle() } label: {
          HStack(spacing: 3) {
            Text(store.availableModels.first(where: { $0.id == store.selected?.modelID })?.name ?? store.selected?.modelID ?? "选择模型").lineLimit(1)
            Image(systemName: "chevron.down")
          }.font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(.primary).disabled(store.isBusy)
          .accessibilityLabel("选择模型")
          .popover(isPresented: $showModels) { ModelPicker(store: store) }
      }.foregroundStyle(.tertiary)
      }
    }.padding(16).background(.primary.opacity(0.025))
  }
}

struct TimelineView: View {
  @Environment(\.providerAccent) private var accent
  var conversation: Conversation
  @State private var followLatest = true
  @State private var visibleCount = 100
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if conversation.items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
              Image(systemName: "bubble.left.and.text.bubble.right").font(
                .system(size: 29, weight: .light)
              ).foregroundStyle(accent).padding(.bottom, 8)
              Text(conversation.engine == .claude ? "和 Claude，接着聊。" : conversation.engine == .api ? "开始新的对话。" : "随时，接着想。").font(.system(size: 26, weight: .medium))
              Text(conversation.engine == .codex ? "聊一个想法，理清一个问题，\n或选好项目，把事情交给 Codex。" : "当前连接有独立的历史、草稿与模型。\n其他连接的对话不会自动带入。").font(.system(size: 14)).foregroundStyle(
                .secondary
              ).lineSpacing(6)
              Label("收起侧栏，任务仍会继续", systemImage: "arrow.left.to.line").font(.caption)
                .foregroundStyle(.tertiary).padding(.top, 12)
            }.padding(.top, 50).padding(.bottom, 20)
          }
          if conversation.items.count > visibleCount {
            Button("载入更早的消息") { followLatest = false; visibleCount += 100 }
          }
          ForEach(conversation.items.suffix(visibleCount)) { item in MessageView(item: item) }
          if let error = conversation.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
              .orange
            ).textSelection(.enabled)
          }
          if conversation.status == .running {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("AI 正在处理…").font(.caption).foregroundStyle(.secondary)
            }
          }
          Color.clear.frame(height: 1).id("bottom")
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(TimelineScrollObserver { followLatest = false })
      .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in followLatest = false })
      .overlay(alignment: .bottomTrailing) {
        if !followLatest {
          Button {
            followLatest = true; proxy.scrollTo("bottom", anchor: .bottom)
          } label: { Label("最新消息", systemImage: "arrow.down").font(.caption) }
          .buttonStyle(.bordered).background(.regularMaterial, in: Capsule()).padding(10)
        }
      }
      .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
      .onChange(of: conversation.items) { _, _ in
        if followLatest { proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
  }
}
struct MessageView: View {
  @Environment(\.providerAccent) private var accent
  let item: TimelineItem
  var body: some View {
    if item.kind == "userMessage" {
      HStack {
        Spacer(minLength: 25)
        VStack(alignment: .trailing, spacing: 8) {
          if let images = item.attachments, !images.isEmpty {
            ForEach(images) { image in AttachmentThumbnail(attachment: image, width: 180, height: 140) }
          }
          if !item.text.isEmpty { Text(item.text).textSelection(.enabled).font(.system(size: 14)) }
        }.padding(13).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
      }
    } else if item.kind == "agentMessage" {
      VStack(alignment: .leading, spacing: 10) {
        Text("AI").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(
          .secondary)
        MarkdownBody(text: item.text)
        Button {
          copy(item.text)
        } label: {
          Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.buttonStyle(.plain).help("复制回复")
      }
    } else if item.kind != "reasoning" || !item.detail.isEmpty {
      DisclosureGroup {
        ScrollView(.horizontal) {
          Text(item.detail.isEmpty ? item.text : item.detail).font(
            .system(size: 11, design: .monospaced)
          ).textSelection(.enabled).padding(.vertical, 8)
        }
      } label: {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: item.kind == "fileChange" ? "doc.badge.gearshape" : "terminal")
          Text(item.text.isEmpty ? "执行步骤" : item.text).lineLimit(2)
          Spacer()
          Text(
            item.status == "inProgress"
              ? "进行中" : item.status == "failed" ? "失败" : item.status == "declined" ? "已拒绝" : ""
          ).font(.caption2)
        }.font(.caption).foregroundStyle(.secondary)
      }.padding(11).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}
private func copy(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
struct MarkdownBody: View {
  let text: String
  var body: some View {
    let parts = text.components(separatedBy: "```")
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
        if index % 2 == 1 {
          let lines = part.components(separatedBy: "\n")
          let code = lines.dropFirst().joined(separator: "\n")
          VStack(spacing: 0) {
            HStack {
              Text(lines.first ?? "code").font(.caption2)
              Spacer()
              Button {
                copy(code)
              } label: {
                Image(systemName: "doc.on.doc")
              }.buttonStyle(.plain).help("复制代码")
            }.foregroundStyle(.secondary).padding(9)
            Divider()
            ScrollView(.horizontal) {
              Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .padding(12)
            }
          }.background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        } else if !part.isEmpty {
          Text(
            (try? AttributedString(
              markdown: part, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
              ?? AttributedString(part)
          ).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
