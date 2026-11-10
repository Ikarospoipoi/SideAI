import SwiftUI
import SideAICore

struct MemoryIndicator: View {
  @ObservedObject var store: SessionStore
  @State private var showing = false
  var body: some View {
    HStack {
      Button { showing.toggle() } label: {
        Label(store.selected.map { store.memoryEnabled(for: $0) } == true ? "跨会话记忆 · 已开启" : "跨会话记忆 · 已关闭", systemImage: "brain")
      }.buttonStyle(.plain).popover(isPresented: $showing) { MemoryPreviewView(store: store, dismiss: { showing = false }) }
      Spacer()
      if store.preparingMemory { ProgressView().controlSize(.small); Text("正在查找历史…") }
      else { Text("查看来源与设置").foregroundStyle(.tertiary) }
    }.font(.caption).foregroundStyle(.secondary)
  }
}
struct MemoryPreviewView: View {
  @ObservedObject var store: SessionStore
  var dismiss: () -> Void
  @State private var context = MemoryContext()
  @State private var loading = false
  @State private var request = UUID()
  @State private var previewDraft = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack { Text("跨会话记忆").font(.headline); Spacer(); Button("关闭", action: dismiss) }
      Text("从聊天、Agent 和导入记录中查找相关背景。发送时，仅将命中的摘录和记忆笔记交给当前连接的服务商；不是官网账号的云端记忆。").font(.caption).foregroundStyle(.secondary)
      if let c = store.selected {
        Toggle("本会话使用记忆", isOn: Binding(get: { c.memoryEnabled != false }, set: { value in store.mutate(c.id) { $0.memoryEnabled = value }; request = UUID() })).disabled(store.isBusy)
        Toggle("允许其他会话引用这条会话", isOn: Binding(get: { c.memoryExcluded != true }, set: { value in store.mutate(c.id) { $0.memoryExcluded = !value }; request = UUID() })).disabled(store.isBusy)
        if store.settings.crossConversationMemory == false { Text("全局记忆已关闭，可在设置 → 跨会话记忆开启。").font(.caption) }
        HStack { Button("按当前输入查找") { request = UUID() }; if loading { ProgressView().controlSize(.small) } }
        if previewDraft != c.draft { Text("输入已改变，点击查找可更新预览；发送时会重新检索。").font(.caption).foregroundStyle(.secondary) }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if context.isEmpty && !loading { Text("未找到相关历史。可以写出主题、表名或项目名；例如“之前的 SQL 中 TRACE_ID 怎么关联”。").font(.caption).foregroundStyle(.secondary) }
          if !context.notes.isEmpty { Text("记忆笔记").font(.headline); Text(context.notes).font(.caption).textSelection(.enabled) }
          ForEach(context.sources) { source in
            VStack(alignment: .leading, spacing: 6) {
              Text(source.title).font(.headline)
              Text(source.excerpt).font(.caption).textSelection(.enabled)
              HStack {
                Button("打开原会话") { if let id = UUID(uuidString: source.id) { store.select(id); dismiss(); store.onRouteOpen?() } }
                Button("不再引用") { if let id = UUID(uuidString: source.id) { store.mutate(id) { $0.memoryExcluded = true }; request = UUID() } }.disabled(store.isBusy)
              }.controlSize(.small)
            }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
          }
          if let previous = store.selected?.lastMemory, !previous.isEmpty {
            DisclosureGroup("上次发送引用的来源") { Text(previous.sources.map(\.title).joined(separator: "、") + (previous.notes.isEmpty ? "" : " · 记忆笔记")).font(.caption) }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Text("最多 4 条相关会话摘录；没有命中不代表历史不存在。关闭记忆只影响后续发送，已发给原会话后端的上下文不会被撤回。").font(.caption2).foregroundStyle(.secondary)
    }.padding(16).frame(width: 440, height: 540)
      .task(id: request) {
        guard let c = store.selected else { return }
        loading = true; previewDraft = c.draft
        let result = await store.memoryContext(for: c)
        guard !Task.isCancelled else { return }; context = result; loading = false
      }
  }
}
