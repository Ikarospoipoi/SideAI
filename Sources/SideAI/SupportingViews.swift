import AppKit
import SideAICore
import SwiftUI

struct ApprovalCard: View {
  @ObservedObject var store: SessionStore
  let request: PendingRequest
  @State private var answers = [String: String]()
  @State private var showDetails = false
  private var source: Conversation? {
    store.state.conversations.first { $0.threadID == request.threadID }
  }
  private var details: String {
    if request.method == "item/fileChange/requestApproval",
      let item = source?.items.first(where: { $0.id == request.itemID })
    {
      return item.detail + "\n" + request.params.pretty
    }
    return request.params.pretty
  }
  private var supportedAccept: Bool {
    let decisions = request.params["availableDecisions"].array
    return decisions.isEmpty || decisions.contains(.string("accept"))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(
          request.isQuestion ? "需要你的回答" : "需要你的确认",
          systemImage: request.isQuestion ? "questionmark.bubble" : "hand.raised.fill"
        ).font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
        Spacer()
        Text(request.receivedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
      }
      Text(source?.title ?? "任务").font(.caption.weight(.medium))
      Text(request.params["cwd"].string ?? source?.cwd ?? "").font(
        .system(size: 10, design: .monospaced)
      ).foregroundStyle(.secondary).textSelection(.enabled)
      if let reason = request.params["reason"].string {
        Text(reason).font(.caption).textSelection(.enabled)
      }
      if let command = request.params["command"].string {
        ScrollView(.horizontal) {
          Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .padding(8)
        }.background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      }
      if request.params["networkApprovalContext"] != .null {
        Text("网络访问：" + request.params["networkApprovalContext"].pretty).font(.caption)
          .textSelection(.enabled)
      }
      if request.isQuestion {
        ForEach(request.params["questions"].array, id: \.pretty) { q in
          VStack(alignment: .leading, spacing: 6) {
            Text(q["question"].text).font(.caption)
            ForEach(q["options"].array, id: \.pretty) { option in
              Button {
                answers[q["id"].text] = option["label"].text
              } label: {
                VStack(alignment: .leading) {
                  Label(
                    option["label"].text,
                    systemImage: answers[q["id"].text] == option["label"].text
                      ? "checkmark.circle.fill" : "circle")
                  if let d = option["description"].string {
                    Text(d).font(.caption2).foregroundStyle(.secondary)
                  }
                }
              }.buttonStyle(.plain).font(.caption)
            }
            if q["isSecret"].bool {
              SecureField("输入回答", text: answerBinding(q["id"].text)).textFieldStyle(.roundedBorder)
            } else {
              TextField("输入回答", text: answerBinding(q["id"].text)).textFieldStyle(.roundedBorder)
            }
          }
        }
      }
      if request.method == "item/permissions/requestApproval" {
        Text("本次回合权限：").font(.caption)
        Text(request.params["permissions"].pretty).font(.system(size: 10, design: .monospaced))
          .textSelection(.enabled)
      }
      DisclosureGroup("查看完整请求", isExpanded: $showDetails) {
        ScrollView([.horizontal, .vertical]) {
          Text(details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }.frame(maxHeight: 140)
      }.font(.caption2).foregroundStyle(.secondary)
      HStack {
        if request.submitted {
          ProgressView().controlSize(.small)
          Text("已提交，等待后端确认…").font(.caption)
        } else if request.isQuestion {
          Button("停止任务") { if let id = source?.id { store.interrupt(id) } }
          Spacer()
          Button("提交回答") { store.respond(request, allow: true, answers: answers) }.buttonStyle(
            .borderedProminent
          ).disabled(
            request.params["questions"].array.contains {
              (answers[$0["id"].text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        } else {
          Button("拒绝") { store.respond(request, allow: false) }
          Spacer()
          Button(request.method == "item/permissions/requestApproval" ? "允许本回合" : "仅批准这一次") {
            store.respond(request, allow: true)
          }.buttonStyle(.borderedProminent).tint(.orange).disabled(!supportedAccept)
        }
      }.controlSize(.small)
    }.padding(13).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).overlay(
      RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.25)))
  }
  private func answerBinding(_ key: String) -> Binding<String> {
    Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 })
  }
}

struct SessionPicker: View {
  @ObservedObject var store: SessionStore
  let dismiss: () -> Void
  @State private var search = ""
  @State private var archived = false
  @State private var category = "当前连接"
  @State private var renaming: UUID?
  @State private var title = ""
  private var conversations: [Conversation] {
    store.state.conversations.filter {
      $0.archived == archived && (category == "全部" || (category == "当前模式" ? $0.workspace == store.workspace : $0.routeID == store.currentRoute.id))
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }.sorted { a, b in
      if a.status.isActive != b.status.isActive { return a.status.isActive }
      return a.updatedAt > b.updatedAt
    }
  }
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("会话").font(.headline)
        Spacer()
        Button {
          store.newConversation()
          dismiss()
        } label: {
          Image(systemName: "plus")
        }
      }
      TextField("搜索标题", text: $search).textFieldStyle(.roundedBorder)
      Picker("类型", selection: $category) {
        Text("当前连接").tag("当前连接"); Text("当前模式").tag("当前模式"); Text("全部").tag("全部")
      }.pickerStyle(.segmented)
      HStack {
        Toggle("已归档", isOn: $archived)
        Spacer()
        Button(store.syncing ? "同步中…" : "同步") { store.syncConversations() }.disabled(store.syncing || store.isBusy || !store.ready)
      }.font(.caption)
      Text(store.syncStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
      ScrollView {
        LazyVStack(spacing: 5) {
          if conversations.isEmpty {
            Text("此连接下暂无匹配会话。点击 + 开始新的对话。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 24)
          }
          ForEach(conversations) { c in
            Button {
              store.select(c.id)
              dismiss()
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(c.title).lineLimit(1)
                  Text(store.route(for: c).name + " · " + c.status.label).font(.caption2).foregroundStyle(
                    c.status == .awaitingApproval ? .orange : .secondary)
                }
                Spacer()
                if c.id == store.selectedID { Image(systemName: "checkmark") }
              }.padding(10).contentShape(Rectangle()).background(
                c.id == store.selectedID ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).contextMenu {
              Button("重命名") {
                renaming = c.id
                title = c.title
              }
              Button(c.archived ? "取消归档" : "归档") { store.archive(c.id) }.disabled(c.status.isActive)
            }
          }
        }
      }
    }.padding(16).frame(width: 330, height: 480)
      .alert(
        "重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
      ) {
        TextField("标题", text: $title)
        Button("取消", role: .cancel) { renaming = nil }
        Button("保存") {
          if let id = renaming { store.mutate(id) { $0.title = title.isEmpty ? "未命名会话" : title; $0.locallyRenamed = true } }
          renaming = nil
        }
      }
  }
}

struct AppearanceSettingsView: View {
  @ObservedObject var store: SessionStore
  private let keys: [(String, UInt32)] = [
    ("Space", 49), ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
    ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
    ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16),
    ("Z", 6),
  ]
  var body: some View {
    Form {
      Section("侧栏") {
        Picker("显示器", selection: $store.settings.screenID) {
          Text("主显示器").tag("")
          ForEach(NSScreen.screens, id: \.self) { screen in
            Text(screen.localizedName).tag(EdgePanelController.screenID(screen))
          }
        }
        HStack {
          Text("宽度")
          Slider(value: $store.settings.panelWidth, in: 360...740, step: 10)
          Text("\(Int(store.settings.panelWidth)) pt").monospacedDigit()
        }
        Toggle("待确认时显示非激活预览卡片", isOn: $store.settings.autoPeek)
      }
      Section("全局快捷键") {
        HStack {
          Toggle("⌃", isOn: modifier(4096))
          Toggle("⌥", isOn: modifier(2048))
          Toggle("⌘", isOn: modifier(256))
          Toggle("⇧", isOn: modifier(512))
          Picker("按键", selection: $store.settings.hotkeyCode) {
            ForEach(keys, id: \.1) { key in Text(key.0).tag(key.1) }
          }.frame(width: 135)
        }
        if let error = store.hotkeyError { Text(error).foregroundStyle(.orange).font(.caption) }
        Text("默认 Control + Option + Space。至少选择一个 Control、Option 或 Command 修饰键。").font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("本地数据") {
        Text("会话索引、草稿与缓存保存在 Application Support/SideAI；官方 Codex 管理认证与后端历史。没有额外遥测。").font(.caption)
          .foregroundStyle(.secondary)
        Button("打开数据文件夹") { NSWorkspace.shared.open(store.persistence.directory) }
      }
    }.formStyle(.grouped).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: store.settings.panelWidth) { _, _ in store.updateSettings() }
      .onChange(of: store.settings.screenID) { _, _ in store.settings.panelOriginX = nil; store.settings.panelOriginY = nil; store.updateSettings() }
      .onChange(of: store.settings.hotkeyCode) { _, _ in store.updateSettings() }
      .onChange(of: store.settings.hotkeyModifiers) { _, _ in store.updateSettings() }
      .onChange(of: store.settings.autoPeek) { _, _ in store.saveSoon() }
      .onChange(of: store.settings.cliPath) { _, _ in store.saveSoon() }
  }
  private func modifier(_ mask: UInt32) -> Binding<Bool> {
    Binding(
      get: { store.settings.hotkeyModifiers & mask != 0 },
      set: {
        if $0 {
          store.settings.hotkeyModifiers |= mask
        } else {
          store.settings.hotkeyModifiers &= ~mask
        }
      })
  }
}

struct ComposerEditor: NSViewRepresentable {
  @Binding var text: String
  let send: () -> Void
  var imageFiles: ([URL]) -> Void
  var imageData: (Data) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let editor = ComposerTextView()
    editor.isRichText = false
    editor.drawsBackground = false
    editor.font = .systemFont(ofSize: 14)
    editor.textColor = .labelColor
    editor.textContainerInset = NSSize(width: 6, height: 6)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.delegate = context.coordinator
    editor.send = send
    editor.imageFiles = imageFiles
    editor.imageData = imageData
    editor.registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    editor.string = text
    scroll.documentView = editor
    context.coordinator.editor = editor
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: .sideAIFocusComposer, object: nil, queue: .main
    ) { [weak editor] _ in
      if let editor, editor.window?.isKeyWindow == true {
        editor.window?.makeFirstResponder(editor)
      }
    }
    editor.setAccessibilityLabel("消息输入框")
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = view.documentView as? ComposerTextView else { return }
    editor.send = send
    editor.imageFiles = imageFiles
    editor.imageData = imageData
    if editor.string != text && !editor.hasMarkedText() { editor.string = text }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposerEditor
    weak var editor: ComposerTextView?
    var observer: NSObjectProtocol?
    init(_ parent: ComposerEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      if let editor { parent.text = editor.string }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}
final class ComposerTextView: NSTextView {
  var send: (() -> Void)?
  var imageFiles: (([URL]) -> Void)?
  var imageData: ((Data) -> Void)?
  func accept(_ board: NSPasteboard) -> Bool {
    if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
      imageFiles?(urls); return true
    }
    if let data = board.data(forType: .png) ?? board.data(forType: .tiff) { imageData?(data); return true }
    return false
  }
  override func paste(_ sender: Any?) {
    if !accept(.general) { super.paste(sender) }
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let board = sender.draggingPasteboard
    if board.canReadObject(forClasses: [NSFilePromiseReceiver.self, NSURL.self], options: nil) || board.availableType(from: [.png, .tiff]) != nil { return .copy }
    return super.draggingEntered(sender)
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let board = sender.draggingPasteboard
    // Screenshot floating thumbnails may provide a promised file instead of a real URL.
    if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
      let callback = imageFiles
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SideAI-drop-" + UUID().uuidString)
      do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
      for promise in promises {
        promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) { url, error in
          if error == nil { callback?([url]); try? FileManager.default.removeItem(at: url) }
        }
      }
      return true
    }
    if accept(board) { return true }
    return super.performDragOperation(sender)
  }
  override func keyDown(with event: NSEvent) {
    if [36, 76].contains(event.keyCode) && !hasMarkedText() {
      if event.modifierFlags.contains(.shift) { insertNewline(nil) }
      else { send?() }
      return
    }
    super.keyDown(with: event)
  }
}

/// Track deliberate wheel scrolling without relying on visibility callbacks in a lazy stack.
struct TimelineScrollObserver: NSViewRepresentable {
  var onScroll: () -> Void
  func makeNSView(context: Context) -> ScrollObserverView { let view = ScrollObserverView(); view.onScroll = onScroll; return view }
  func updateNSView(_ view: ScrollObserverView, context: Context) { view.onScroll = onScroll }
}
final class ScrollObserverView: NSView {
  var onScroll: (() -> Void)?
  private var monitor: Any?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      if let self, event.window == self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0 {
        self.onScroll?()
      }
      return event
    }
  }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
