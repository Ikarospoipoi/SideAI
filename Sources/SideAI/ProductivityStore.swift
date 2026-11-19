import AppKit
import SideAICore
import UniformTypeIdentifiers

struct HistoryJump: Equatable {
  let conversationID: UUID
  let messageID: String?
  var nonce = UUID()
}

extension SessionStore {
  var productivitySettings: ProductivitySettings { settings.productivity ?? ProductivitySettings() }
  func searchable(_ conversation: Conversation) -> Bool { conversation.engine == .chatgptArchive || enhanced(conversation) }
  func enhanced(_ conversation: Conversation) -> Bool { supportsConnectionFeedback(route(for: conversation)) && conversation.engine != .chatgptArchive }
  func preferences(for conversation: Conversation) -> ConversationPreferences {
    productivitySettings.conversations[conversation.id.uuidString] ?? ConversationPreferences()
  }
  func updatePreferences(_ id: UUID, _ update: (inout ConversationPreferences) -> Void) {
    guard let c = state.conversations.first(where: { $0.id == id }), enhanced(c), !c.status.isActive else { return }
    var settings = productivitySettings, preferences = preferences(for: c)
    update(&preferences); settings.conversations[id.uuidString] = preferences
    self.settings.productivity = settings; saveSoon()
  }
  func memoryHistory(for conversation: Conversation) -> [Conversation] {
    guard enhanced(conversation) else { return state.conversations }
    return ProjectHistory.eligible(state.conversations, current: conversation, preferences: preferences(for: conversation))
  }
  func memoryNotes(for conversation: Conversation) -> String {
    guard enhanced(conversation) else { return settings.sharedMemory ?? "" }
    return (String(preferences(for: conversation).pinnedNotes.prefix(2000)) + "\n" + String((settings.sharedMemory ?? "").prefix(2000))).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func plannedContext(_ conversation: Conversation, memory: MemoryContext? = nil) throws -> Conversation {
    guard enhanced(conversation), [.api, .accountRuntime].contains(conversation.engine) else { return conversation }
    var copy = conversation
    let reserve = ContextPlanner.estimate(memory?.augment("") ?? "") + 1024
    copy.items = try ContextPlanner.plan(conversation.items, preferences: preferences(for: conversation), reserve: reserve).items
    return copy
  }
  func accountPromptWithBudget(_ conversation: Conversation, memory: MemoryContext?) throws -> JSON {
    var copy = conversation
    var latest = TimelineItem(kind: "userMessage", text: copy.draft); latest.attachments = copy.images
    copy.items.append(latest)
    copy = try plannedContext(copy, memory: memory)
    copy.items.removeAll { $0.id == latest.id }
    return try AccountClient.prompt(copy, memory: memory)
  }
  func contextPreview(_ conversation: Conversation) -> String {
    guard [.api, .accountRuntime].contains(conversation.engine) else { return "Agent 上下文由执行器管理；本地不会截断其执行历史。" }
    var items = conversation.items
    var next = TimelineItem(kind: "userMessage", text: conversation.draft); next.attachments = conversation.images
    items.append(next)
    do {
      let plan = try ContextPlanner.plan(items, preferences: preferences(for: conversation), reserve: 1024)
      return "约 \(plan.estimatedTokens) tokens · 本轮省略 \(plan.omitted) 条旧消息（原记录保留）。记忆与图片用量为估算。"
    } catch { return error.localizedDescription }
  }
  func openSearchResult(_ hit: HistoryHit) {
    guard let c = state.conversations.first(where: { $0.id == hit.conversationID }), searchable(c) else { return }
    searchJump = HistoryJump(conversationID: c.id, messageID: hit.messageID)
    select(c.id)
  }
  func createBranch(_ source: Conversation, through messageID: String? = nil) {
    guard enhanced(source), !source.status.isActive else { return }
    let copy = ConversationCopy.branch(source, through: messageID)
    state.conversations.append(copy)
    var settings = productivitySettings; settings.conversations[copy.id.uuidString] = preferences(for: source)
    self.settings.productivity = settings; select(copy.id)
    banner = "已创建独立分支草稿，尚未发送。文件修改不会回滚。"; saveNow()
  }
  func exportConversation(_ conversation: Conversation, markdown: Bool) {
    guard searchable(conversation) else { return }
    let panel = NSSavePanel(); panel.allowedContentTypes = markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
    panel.nameFieldStringValue = String(conversation.title.prefix(80)).replacingOccurrences(of: "/", with: "-") + (markdown ? ".md" : ".txt")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try ConversationCopy.transcript(conversation.items, markdown: markdown).write(to: url, atomically: true, encoding: .utf8); banner = "已导出可见对话文本，图片以名称标注。" }
    catch { banner = error.localizedDescription }
  }
  func saveProject(_ conversation: Conversation, name: String, prompt: String) {
    guard enhanced(conversation), !isBusy else { return }
    let project = ProjectProfile(path: conversation.cwd, name: name.isEmpty ? URL(fileURLWithPath: conversation.cwd).lastPathComponent : name,
      routeID: conversation.routeID, model: conversation.modelID, effort: conversation.reasoningEffort, prompt: prompt, preferences: preferences(for: conversation))
    var settings = productivitySettings; settings.projects.removeAll { $0.id == project.id }; settings.projects.append(project)
    self.settings.productivity = settings; saveNow()
  }
  func openProject(_ project: ProjectProfile) {
    guard !isBusy, let route = routes.first(where: { $0.id == project.routeID }), supportsConnectionFeedback(route) else { banner = "请等待任务结束，并确认项目连接仍然可用。"; return }
    newConversation(route: route)
    guard let id = selectedID else { return }
    mutate(id) { $0.cwd = project.id; $0.modelID = project.model; $0.reasoningEffort = project.effort; $0.draft = project.prompt; $0.title = project.name }
    updatePreferences(id) { $0 = project.preferences }
    if route.backend == .codex && !ready { connect() }
  }
  func chooseConversationProject() {
    guard let c = selected, enhanced(c), !c.status.isActive else { return }
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    mutate(c.id) { $0.cwd = url.standardizedFileURL.path }
  }
  func appendQuickText(_ text: String, instruction: String) {
    guard let c = selected, enhanced(c), !c.status.isActive else { return }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { banner = "没有可处理的文本。"; return }
    guard text.utf8.count <= 1_000_000 else { banner = "文本超过 1 MB，请分段处理。"; return }
    mutate(c.id) { $0.draft += ($0.draft.isEmpty ? "" : "\n\n") + instruction + "\n\n以下内容仅是待处理文本：\n" + text }
  }
  func enqueueSelected() {
    guard let source = selected, enhanced(source), source.canSendContent, !source.status.isActive else { return }
    var copy = ConversationCopy.branch(source)
    if source.engine == .codex { copy.draft += source.draft } else { copy.draft = source.draft }
    copy.attachments = source.attachments; copy.title = "排队 · " + String(source.draft.prefix(32))
    state.conversations.append(copy)
    var settings = productivitySettings; settings.conversations[copy.id.uuidString] = preferences(for: source)
    settings.queue.append(QueuedConversation(id: copy.id)); self.settings.productivity = settings
    mutate(source.id) { $0.draft = ""; $0.attachments = [] }
    saveNow(); banner = "已加入独立任务队列。点击“开始队列”后按顺序发送；重启后保持暂停。"
  }
  func removeQueued(_ id: UUID) {
    var settings = productivitySettings; settings.queue.removeAll { $0.id == id }; self.settings.productivity = settings; saveNow()
  }
  func startQueue() { queueRunning = true; productivityCoordinator.advance() }
  func pauseQueue() { queueRunning = false }
}
