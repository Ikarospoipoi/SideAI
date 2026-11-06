import AppKit
import SideAICore
import SwiftUI

extension ProviderKind {
  var launcherName: String {
    switch self { case .openai: return "GPT / Codex"; case .custom: return "其他 AI"; default: return label }
  }
  var monogram: String {
    switch self { case .openai: return "G"; case .anthropic: return "C"; case .deepseek: return "D"; case .kimi: return "K"; case .qwen: return "Q"; case .gemini: return "G"; case .grok: return "X"; case .openrouter: return "O"; case .custom: return "+" }
  }
  var accentColor: Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      switch self {
      case .openai: return dark ? NSColor(red: 0.49, green: 0.75, blue: 0.66, alpha: 1) : NSColor(red: 0.22, green: 0.40, blue: 0.36, alpha: 1)
      case .anthropic: return dark ? NSColor(red: 0.94, green: 0.58, blue: 0.36, alpha: 1) : NSColor(red: 0.70, green: 0.32, blue: 0.14, alpha: 1)
      case .deepseek, .gemini: return dark ? NSColor(red: 0.40, green: 0.62, blue: 1, alpha: 1) : NSColor(red: 0.16, green: 0.36, blue: 0.80, alpha: 1)
      case .kimi: return dark ? NSColor(red: 0.38, green: 0.79, blue: 0.83, alpha: 1) : NSColor(red: 0.08, green: 0.45, blue: 0.49, alpha: 1)
      case .qwen: return dark ? NSColor(red: 0.73, green: 0.59, blue: 1, alpha: 1) : NSColor(red: 0.49, green: 0.30, blue: 0.78, alpha: 1)
      case .custom, .grok, .openrouter: return .secondaryLabelColor
      }
    })
  }
}
private struct ProviderAccentKey: EnvironmentKey {
  static let defaultValue = ProviderKind.openai.accentColor
}
extension EnvironmentValues {
  var providerAccent: Color {
    get { self[ProviderAccentKey.self] }
    set { self[ProviderAccentKey.self] = newValue }
  }
}

struct WindowDragArea: NSViewRepresentable {
  var finished: () -> Void
  func makeNSView(context: Context) -> WindowDragView { let view = WindowDragView(); view.finished = finished; return view }
  func updateNSView(_ view: WindowDragView, context: Context) { view.finished = finished }
}
final class WindowDragView: NSView {
  var finished: (() -> Void)?
  private var dragStart: CGPoint?
  private var originalOrigin: CGPoint?
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true); setAccessibilityLabel("拖动窗口"); setAccessibilityRole(.group)
    toolTip = "拖动以移动窗口"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    dragStart = window.convertPoint(toScreen: event.locationInWindow)
    originalOrigin = window.frame.origin
  }
  override func mouseDragged(with event: NSEvent) {
    guard let window, let dragStart, let originalOrigin else { return }
    let point = window.convertPoint(toScreen: event.locationInWindow)
    window.setFrameOrigin(CGPoint(x: originalOrigin.x + point.x - dragStart.x,
                                  y: originalOrigin.y + point.y - dragStart.y))
  }
  override func mouseUp(with event: NSEvent) {
    guard dragStart != nil else { return }
    dragStart = nil; originalOrigin = nil
    finished?()
  }
}
