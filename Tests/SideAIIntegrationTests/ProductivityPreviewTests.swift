import AppKit
import SwiftUI
import XCTest
import SideAICore
@testable import SideAI

final class ProductivityPreviewTests: XCTestCase {
  @MainActor func testOfflineRendering() throws {
    guard let path = ProcessInfo.processInfo.environment["SIDEAI_PREVIEW_DIR"] else { throw XCTSkip("Explicit offline preview only") }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = directory.appendingPathComponent("fixture")
    let store = SessionStore(directory: data); defer { store.shutdown() }
    let profile = ProviderKind.deepseek.preset(); store.settings.apiProfiles = [profile]; store.newConversation(route: .api(profile))
    store.mutate(store.selectedID!) { $0.title = "项目 SQL 优化"; $0.draft = "检查这一段查询" }
    let samples: [(String, AnyView)] = [
      ("workbench", AnyView(ProductivityView(store: store, dismiss: {}).background(Color(nsColor: .windowBackgroundColor)))),
      ("markdown", AnyView(RichMarkdownView(text: "# 查询优化建议\n先验证结果，再对比执行计划。\n- 保留原始记录\n- 检查索引命中\n| 项目 | 状态 |\n| --- | --- |\n| 本地测试 | 通过 |\n| 真实连接 | 未调用 |\n```sql\nSELECT name, count(*)\nFROM users\nWHERE active = true\n```\n> 此处仅为离线界面样例。").padding(22).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))))
    ]
    _ = NSApplication.shared
    for (name, view) in samples {
      let size = name == "workbench" ? NSSize(width: 680, height: 600) : NSSize(width: 460, height: 500)
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
      let host = NSHostingView(rootView: view); window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      window.contentView = nil
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      XCTAssertGreaterThan(png.count, 1000)
    }
    XCTAssertTrue(store.apiTasks.isEmpty); XCTAssertFalse(store.connecting)
  }
}
