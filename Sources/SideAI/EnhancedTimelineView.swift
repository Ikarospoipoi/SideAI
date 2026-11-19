import AppKit
import SideAICore
import SwiftUI

struct EnhancedTimelineView: View {
  @ObservedObject var store: SessionStore
  let conversation: Conversation
  @State private var visibleCount = 100
  @State private var position: String?
  @State private var follow = true
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if conversation.items.isEmpty { Text("开始新的对话。\n可以打开工作台，导入文本或选择项目。").font(.title3).foregroundStyle(.secondary).padding(.vertical, 40) }
          if conversation.items.count > visibleCount { Button("载入更早的消息") { visibleCount += 100; follow = false } }
          ForEach(conversation.items.suffix(visibleCount)) { item in
            VStack(alignment: .leading, spacing: 8) {
              if item.kind == "agentMessage", !item.text.isEmpty { RichMarkdownView(text: item.text).equatable() }
              else { MessageView(item: item) }
              if let memory = item.memory { MemorySourcesView(memory: memory, openSource: { id in if let uuid = UUID(uuidString: id) { store.select(uuid) } }) }
            }.id(item.id).contextMenu {
              Button("复制文本") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string) }
              if store.enhanced(conversation), ["userMessage", "agentMessage"].contains(item.kind), item.status == "completed" {
                Button("从这里创建分支") { store.createBranch(conversation, through: item.id) }.disabled(conversation.status.isActive)
              }
            }
          }
          if let error = conversation.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
          if let diagnostic = conversation.lastHTTPFailure { DisclosureGroup("请求诊断") { Text(diagnostic.summary).font(.caption).textSelection(.enabled) } }
          if conversation.status.isActive { ProgressView(conversation.status.label).controlSize(.small) }
          Color.clear.frame(height: 1).id("bottom")
        }.scrollTargetLayout().padding(22)
      }.scrollPosition(id: $position, anchor: .top)
        .background(TimelineScrollObserver { follow = false })
        .overlay(alignment: .bottomTrailing) {
          Button("最新消息 ↓") { follow = true; proxy.scrollTo("bottom", anchor: .bottom) }.buttonStyle(.bordered).padding(10)
        }
        .onAppear {
          let target = store.searchJump?.conversationID == conversation.id ? store.searchJump?.messageID : store.readingPositions[conversation.id]
          reveal(target, proxy: proxy)
          if store.searchJump?.conversationID == conversation.id { store.searchJump = nil }
        }
        .onChange(of: store.searchJump) { _, jump in if jump?.conversationID == conversation.id { reveal(jump?.messageID, proxy: proxy); store.searchJump = nil } }
        .onChange(of: position) { _, value in if let value { store.readingPositions[conversation.id] = value } }
        .onChange(of: conversation.items) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
    }
  }
  private func reveal(_ id: String?, proxy: ScrollViewProxy) {
    if let id, let index = conversation.items.firstIndex(where: { $0.id == id }) {
      visibleCount = max(100, conversation.items.count - index); follow = false
      DispatchQueue.main.async { position = id; proxy.scrollTo(id, anchor: .top) }
    } else { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
  }
}

struct RichMarkdownView: View, Equatable {
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(MarkdownSections.parse(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .code(let language, let source):
          VStack(alignment: .leading, spacing: 6) {
            HStack { Text(language.isEmpty ? "代码" : language).font(.caption); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string) }.buttonStyle(.plain) }
            ScrollView(.horizontal) { Text(highlight(source)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
          }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
          ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
              ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell).fontWeight(i == 0 ? .semibold : .regular).frame(minWidth: 70, maxWidth: 240, alignment: .leading) } }
                if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
              }
            }.padding(10)
          }.background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        case .text(let line):
          if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            inline(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)).font(level < 3 ? .title3 : .headline)
          } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top) { Text("•"); inline(String(line.dropFirst(2))) }
          } else if line.hasPrefix("> ") {
            inline(String(line.dropFirst(2))).foregroundStyle(.secondary).padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
          } else { inline(line) }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
  }
  private func inline(_ text: String) -> Text {
    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
  }
  private func highlight(_ source: String) -> AttributedString {
    var result = AttributedString(source)
    guard source.count < 100_000, let regex = try? NSRegularExpression(pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\b(?:func|let|var|if|else|return|class|struct|import|def|for|while|const|function|async|await|true|false|null|None|SELECT|FROM|WHERE)\b|\b[0-9]+(?:\.[0-9]+)?\b"#) else { return result }
    for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
      guard let range = Range(match.range, in: source), let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
      let token = source[range]
      result[lower..<upper].foregroundColor = token.first == "\"" || token.first == "'" ? .green : token.first?.isNumber == true ? .orange : .purple
    }
    return result
  }
}
enum MarkdownSection { case text(String), code(String, String), table([[String]]) }
enum MarkdownSections {
  static func parse(_ text: String) -> [MarkdownSection] {
    let lines = text.components(separatedBy: "\n")
    var result: [MarkdownSection] = [], index = 0
    while index < lines.count {
      let line = lines[index]
      if line.hasPrefix("```") {
        let language = String(line.dropFirst(3)); index += 1; var body: [String] = []
        while index < lines.count && !lines[index].hasPrefix("```") { body.append(lines[index]); index += 1 }
        result.append(.code(language, body.joined(separator: "\n"))); if index < lines.count { index += 1 }
      } else if line.contains("|"), index + 1 < lines.count, separator(lines[index + 1]) {
        var rows = [cells(line)]; index += 2
        while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty { rows.append(cells(lines[index])); index += 1 }
        result.append(.table(rows))
      } else { if !line.isEmpty { result.append(.text(line)) }; index += 1 }
    }
    return result
  }
  private static func cells(_ line: String) -> [String] {
    var value = line.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
    return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }
  private static func separator(_ line: String) -> Bool {
    let row = cells(line)
    return !row.isEmpty && row.allSatisfy { $0.filter { $0 == "-" }.count >= 3 && $0.allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace } }
  }
}
