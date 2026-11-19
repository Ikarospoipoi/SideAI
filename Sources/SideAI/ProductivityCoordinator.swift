import Combine
import Foundation
import SideAICore
import UserNotifications

@MainActor final class ProductivityCoordinator {
  private weak var store: SessionStore?
  private var observation: AnyCancellable?
  private var current: UUID?
  private var statuses: [UUID: SessionStatus] = [:]
  init(store: SessionStore) {
    self.store = store
    statuses = Dictionary(uniqueKeysWithValues: store.state.conversations.map { ($0.id, $0.status) })
    observation = store.objectWillChange.debounce(for: .milliseconds(200), scheduler: RunLoop.main).sink { [weak self] in
      Task { @MainActor in self?.notifyChanges(); self?.advance() }
    }
  }
  func advance() {
    guard let store, store.queueRunning else { return }
    if let id = current, let c = store.state.conversations.first(where: { $0.id == id }) {
      if c.status.isActive { return }
      current = nil
      if c.status != .completed { store.queueRunning = false; store.banner = "队列已暂停：上一项未正常完成。请核对结果，剩余任务不会自动发送。"; return }
    }
    guard !store.isBusy, !store.syncing, !store.connecting else { return }
    guard let next = store.productivitySettings.queue.first else { store.queueRunning = false; return }
    guard let c = store.state.conversations.first(where: { $0.id == next.id }), store.enhanced(c), !c.archived,
      c.canSendContent, store.routes.contains(where: { $0.id == c.routeID }) else {
      store.queueRunning = false; store.banner = "队列已暂停：下一项缺少草稿、连接，或已归档。请在任务中心处理。"; return
    }
    guard c.engine != .codex || store.ready else { store.queueRunning = false; store.banner = "请先连接 Codex，再开始队列。"; return }
    if c.engine == .codex, c.threadID != nil, !store.restored.contains(c.id) {
      store.queueRunning = false; store.select(c.id); store.banner = "请等待这条任务的历史同步完成，再开始队列。"; return
    }
    guard store.activate(store.route(for: c)) else { store.queueRunning = false; return }
    store.select(c.id)
    guard store.canSend else { store.queueRunning = false; store.banner = "队列已暂停，请检查下一项的连接和输入。"; return }
    // Remove before sending: a crash must never replay a possibly executed task.
    do { try store.commitQueuedDispatch(c.id) }
    catch { store.queueRunning = false; store.banner = "队列未发送：" + error.localizedDescription; return }
    current = c.id
    store.send()
  }
  func setNotifications(_ enabled: Bool) {
    guard let store else { return }
    if !enabled { var settings = store.productivitySettings; settings.notifications = false; store.settings.productivity = settings; store.saveSoon(); return }
    Task {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        var settings = store.productivitySettings; settings.notifications = granted; store.settings.productivity = settings; store.saveSoon()
        if !granted { store.banner = "通知未获授权，可在系统设置中允许 SideAI 通知。" }
      } catch { store.banner = error.localizedDescription }
    }
  }
  private func notifyChanges() {
    guard let store else { return }
    for c in store.state.conversations {
      let old = statuses[c.id]; statuses[c.id] = c.status
      guard store.productivitySettings.notifications, store.enhanced(c), old != nil, old != c.status,
        [.awaitingApproval, .awaitingInput, .completed, .failed].contains(c.status) else { continue }
      let content = UNMutableNotificationContent()
      content.title = "SideAI · " + c.status.label
      content.body = "打开 SideAI 查看任务详情。"; content.sound = .default
      UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: c.id.uuidString, content: content, trigger: nil))
    }
  }
}
