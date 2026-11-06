import AppKit
import Carbon
import SideAICore
import SwiftUI

final class EdgePanel: NSPanel {
  var acceptsKeys = false
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  var onEscape: (() -> Void)?
  override var canBecomeKey: Bool { acceptsKeys }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onEscape?() }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil, childWindows?.contains(where: { $0.isVisible }) != true {
      if let input = firstResponder as? NSTextInputClient, input.hasMarkedText() {
        super.sendEvent(event)
        return
      }
      onEscape?()
      return
    }
    super.sendEvent(event)
  }
}
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
  var entered: (() -> Void)?
  var exited: (() -> Void)?
  private var area: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(t)
    area = t
  }
  override func mouseEntered(with event: NSEvent) { entered?() }
  override func mouseExited(with event: NSEvent) { exited?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor final class GlobalHotkey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  var action: (() -> Void)?
  init() {
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { manager.action?() }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
  func register(code: UInt32, modifiers: UInt32) -> Bool {
    if let reference {
      UnregisterEventHotKey(reference)
      self.reference = nil
    }
    guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return false }
    return RegisterEventHotKey(
      code, modifiers, EventHotKeyID(signature: 0x5341_4931, id: 1), GetApplicationEventTarget(), 0,
      &reference) == noErr
  }
  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
  }
}

@MainActor final class EdgePanelController {
  let store: SessionStore
  let panel = EdgePanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
  let handle = EdgePanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
  let preview = EdgePanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
  let hotkey = GlobalHotkey()
  private var previousApp: NSRunningApplication?
  private var hoverTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  private var outsideMonitor: Any?
  private var screenObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?
  private var awaitingActivation = false
  private var menuObservers: [NSObjectProtocol] = []
  private var trackingMenus = 0
  private var menuStartedInPeek = false
  private var persistentPeek = false
  private var grow = false
  var showSettings: (() -> Void)?
  var screen: NSScreen {
    NSScreen.screens.first { Self.screenID($0) == store.settings.screenID } ?? NSScreen.screens
      .first ?? NSScreen.main!
  }
  static func screenID(_ screen: NSScreen) -> String {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
      ?? ""
  }
  init(store: SessionStore) {
    self.store = store
    for window in [panel, handle, preview] {
      window.isFloatingPanel = true
      window.level = .floating
      window.hidesOnDeactivate = false
      window.collectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
      ]
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
    }
    panel.acceptsKeys = true
    // Showing the card does not focus it; an explicit click may focus its native menu.
    preview.acceptsKeys = true
    preview.onEscape = { [weak self] in self?.collapse(restoreFocus: true) }
    panel.title = "SideAI"
    preview.title = "SideAI · 选择 AI"
    handle.title = "SideAI 把手"
    panel.contentView = NSHostingView(rootView: ConversationView(store: store, controller: self))
    panel.onEscape = { [weak self] in
      guard let self else { return }
      if self.store.hasPopover { NotificationCenter.default.post(name: Notification.Name("SideAIDismissPopovers"), object: nil) }
      else { self.collapse(restoreFocus: true) }
    }
    let handleView = TrackingHostingView(
      rootView: HandleView(store: store, open: { [weak self] in self?.expand() }))
    handleView.entered = { [weak self] in self?.hoverEnter() }
    handleView.exited = { [weak self] in self?.hoverExit() }
    handle.contentView = handleView
    let previewView = TrackingHostingView(
      rootView: PeekView(store: store, configure: { [weak self] provider in
        guard let self else { return }
        self.store.apiSetupProvider = provider
        self.collapse(restoreFocus: false)
        self.showSettings?()
      }))
    previewView.entered = { [weak self] in self?.persistentPeek = false; self?.hideTask?.cancel() }
    previewView.exited = { [weak self] in self?.hoverExit() }
    preview.contentView = previewView
    hotkey.action = { [weak self] in self?.toggle() }
    store.onAttention = { [weak self] in
      guard let self else { return }
      if self.store.settings.autoPeek && !self.store.panelState.isOpen { self.showPeek() }
    }
    store.onCompletion = { [weak self] in
      guard let self, self.store.panelState == .collapsed else { return }
      self.showPeek()
      self.hideTask = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if !Task.isCancelled { self.collapse(restoreFocus: false) }
      }
    }
    store.onSettingsChanged = { [weak self] in self?.applySettings() }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])
    { [weak self] event in
      let point = NSEvent.mouseLocation
      MainActor.assumeIsolated {
        guard let self else { return }
        // Global monitors may also observe activation/accessibility-generated clicks.
        // While SideAI owns activation, its own native menus are not outside clicks.
        if NSApp.isActive { return }
        // Accessibility presses may not move the pointer and may carry no target
        // window. Never classify those from the stale global pointer position.
        if event.windowNumber == 0 || NSApp.windows.contains(where: { $0.windowNumber == event.windowNumber }) { return }
        // Nonactivating panels can receive an input event while another app owns activation.
        // Also leave native popup/menu windows alone: local events are not outside clicks.
        if self.trackingMenus > 0 || NSApp.windows.contains(where: {
          $0.isVisible && $0.frame.contains(point)
        }) { return }
        self.outsideClick()
      }
    }
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.layout() } }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.layout() } }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.awaitingActivation else { return }
        self.awaitingActivation = false
        guard self.store.panelState.isOpen else { return }
        self.focusPanel()
      }
    }
    for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
      menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self else { return }
          if note.name == NSMenu.didBeginTrackingNotification && self.trackingMenus == 0 { self.menuStartedInPeek = self.store.panelState == .peek }
          self.trackingMenus = max(0, self.trackingMenus + (note.name == NSMenu.didBeginTrackingNotification ? 1 : -1))
          self.hideTask?.cancel()
          if self.trackingMenus == 0 && self.menuStartedInPeek { self.hoverExit() }
        }
      })
    }
    applySettings()
    handle.orderFrontRegardless()
  }
  func applySettings() {
    store.hotkeyError =
      hotkey.register(code: store.settings.hotkeyCode, modifiers: store.settings.hotkeyModifiers)
      ? nil : "快捷键注册失败或已被占用，请更换组合。菜单栏仍可使用。"
    layout()
  }
  func layout() {
    let f = screen.visibleFrame
    let origin: CGPoint?
    if let x = store.settings.panelOriginX, let y = store.settings.panelOriginY { origin = CGPoint(x: x, y: y) }
    else { origin = nil }
    panel.setFrame(PanelPlacement.frame(origin: origin, width: store.settings.panelWidth, fallback: f,
                                        screens: NSScreen.screens.map(\.visibleFrame)), display: true)
    handle.setFrame(
      NSRect(x: f.minX, y: f.midY - 32, width: grow ? 16 : 9, height: 64), display: true)
    preview.setFrame(
      NSRect(x: f.minX + 8, y: max(f.minY + 8, f.midY - 265), width: 356, height: min(530, f.height - 16)),
      display: true)
  }
  func didDragWindow() {
    store.settings.panelOriginX = panel.frame.minX
    store.settings.panelOriginY = panel.frame.minY
    layout()
    // Preserve partial off-screen placement; only recover an unreachable window.
    store.settings.panelOriginX = panel.frame.minX
    store.settings.panelOriginY = panel.frame.minY
    store.saveSoon()
  }
  func resetPosition() {
    store.settings.panelOriginX = nil; store.settings.panelOriginY = nil
    layout(); store.saveSoon()
  }
  func resize(by translation: CGFloat, start: CGFloat) {
    store.settings.panelWidth = min(740, max(360, start + translation))
    layout()
    store.saveSoon()
  }
  func toggle() {
    // An open panel may have lost focus to a browser (including an OAuth page).
    // In that case the shortcut summons it instead of hiding it.
    if store.panelState.isOpen && panel.isVisible && panel.isOnActiveSpace
      && panel.isKeyWindow && NSApp.isActive {
      collapse(restoreFocus: true)
    } else {
      expand()
    }
  }
  func expand() {
    hoverTask?.cancel()
    hideTask?.cancel()
    let wasVisible = store.panelState.isOpen && panel.isVisible
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previousApp = frontmost
    }
    if store.panelState != .pinned { store.panelState = .expanded }
    preview.orderOut(nil)
    handle.orderOut(nil)
    layout()
    panel.alphaValue = wasVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
    // Activation can complete asynchronously. Raise immediately, then restore
    // keyboard focus when activation finishes, without waiting on a fixed delay.
    awaitingActivation = !NSApp.isActive
    NSApp.activate(ignoringOtherApps: true)
    focusPanel()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.20
      panel.animator().alphaValue = 1
    }
  }
  private func focusPanel() {
    panel.orderFrontRegardless()
    panel.makeKey()
    NotificationCenter.default.post(name: .sideAIFocusComposer, object: nil)
  }
  func collapse(restoreFocus: Bool) {
    hoverTask?.cancel()
    hideTask?.cancel()
    awaitingActivation = false
    grow = false
    let hadFocus = panel.isKeyWindow
    store.panelState = .collapsed
    panel.orderOut(nil)
    preview.orderOut(nil)
    layout()
    handle.orderFrontRegardless()
    if restoreFocus && hadFocus, let previousApp,
      previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      !previousApp.isTerminated
    {
      previousApp.activate(options: [])
    }
    previousApp = nil
  }
  func pin() { store.panelState = store.panelState == .pinned ? .expanded : .pinned }
  private func outsideClick() {
    if store.panelState == .expanded || store.panelState == .peek { collapse(restoreFocus: false) }
  }
  private func hoverEnter() {
    hideTask?.cancel()
    guard !store.panelState.isOpen else { return }
    grow = true
    layout()
    hoverTask?.cancel()
    hoverTask = Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      if !Task.isCancelled { showPeek() }
    }
  }
  private func hoverExit() {
    hoverTask?.cancel()
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(nanoseconds: 450_000_000)
      guard !Task.isCancelled, !store.panelState.isOpen, trackingMenus == 0, !persistentPeek else { return }
      if !preview.frame.contains(NSEvent.mouseLocation)
        && !handle.frame.contains(NSEvent.mouseLocation)
      {
        collapse(restoreFocus: false)
      }
    }
  }
  func showPeek(persistent: Bool = false) {
    guard !store.panelState.isOpen else { return }
    persistentPeek = persistent
    store.panelState = .peek
    handle.orderOut(nil)
    layout()
    preview.orderFrontRegardless()
  }
}
extension Notification.Name {
  static let sideAIFocusComposer = Notification.Name("SideAI.focusComposer")
}
