import AppKit
import SideAICore
import SwiftUI

@main struct SideAIApplication {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var store: SessionStore!
  var controller: EdgePanelController!
  var statusItem: NSStatusItem!
  var settingsWindow: NSWindow?
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Supply standard native text-editing commands even without a Dock menu.
    let main = NSMenu()
    let applicationItem = NSMenuItem(title: "SideAI", action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: "SideAI")
    applicationMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(withTitle: "退出 SideAI", action: #selector(quit), keyEquivalent: "q").target = self
    applicationItem.submenu = applicationMenu
    main.addItem(applicationItem)
    let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "编辑")
    for (title, selector, key) in [
      ("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
      ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
      ("全选", #selector(NSText.selectAll(_:)), "a"),
    ] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
    store = SessionStore()
    store.remoteHost.resume()
    controller = EdgePanelController(store: store)
    controller.showSettings = { [weak self] in self?.settings() }
    store.onRouteOpen = { [weak self] in self?.controller.expand() }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "sidebar.left", accessibilityDescription: "SideAI")
    let menu = NSMenu()
    menu.addItem(withTitle: "显示 / 隐藏 SideAI", action: #selector(toggle), keyEquivalent: "")
    menu.addItem(withTitle: "新建会话", action: #selector(newChat), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
    menu.addItem(withTitle: "后端状态 / 重新连接", action: #selector(reconnect), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出 SideAI", action: #selector(quit), keyEquivalent: "q")
    for item in menu.items { item.target = self }
    statusItem.menu = menu
    if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") {
      Task { do { try await store.resetOnboarding() } catch { store.banner = error.localizedDescription }; controller.expand() }
    } else {
      if store.workspace == .agent, store.selected?.engine == .codex { store.connect() }
      if store.selected?.engine == .claude && store.isRouteActive(store.currentRoute) { store.refreshClaudeStatus() }
      controller.expand()
    }
  }
  @objc func toggle() { controller.toggle() }
  @objc func newChat() {
    store.newConversation()
    controller.expand()
  }
  @objc func reconnect() {
    controller.expand()
    if !store.isBusy { store.connect() } else { store.banner = "后台任务仍在运行。当前后端：\(store.connection)" }
  }
  @objc func settings() {
    store.settingsRequest = UUID()
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 740), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      window.title = "SideAI 设置"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: SettingsView(store: store))
      window.center()
      settingsWindow = window
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc func quit() { NSApp.terminate(nil) }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if store?.isBusy == true {
      let alert = NSAlert()
      alert.messageText = "退出并结束后台连接？"
      alert.informativeText =
        "还有任务正在运行或等待确认。退出会终止 SideAI 的 Codex 进程，不保证外部命令继续运行或已停止；重新打开后可恢复会话检查结果。建议先停止任务。"
      alert.addButton(withTitle: "继续运行")
      alert.addButton(withTitle: "退出")
      if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
    }
    store?.shutdown()
    return .terminateNow
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    controller.expand()
    return false
  }
  func applicationWillTerminate(_ notification: Notification) { store?.shutdown() }
}
