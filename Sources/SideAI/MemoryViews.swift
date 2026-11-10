import SwiftUI
import SideAICore

struct MemoryIndicator: View {
  @ObservedObject var store: SessionStore
  @State private var showing = false
  var body: some View {
    Button { showing.toggle() } label: {
      Label(store.selected.map { store.memoryEnabled(for: $0) } == true ? "记忆已开启" : "记忆已关闭", systemImage: "brain")
        .font(.caption).foregroundStyle(.secondary)
    }.buttonStyle(.plain).help("记忆设置；发送消息后会自动参考相关历史")
      .popover(isPresented: $showing) { MemoryPreviewView(store: store, dismiss: { showing = false }) }
  }
}

/// Settings only: composing a message never starts a separate search UI.
struct MemoryPreviewView: View {
  @ObservedObject var store: SessionStore
  var dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack { Text("记忆设置").font(.headline); Spacer(); Button("关闭", action: dismiss) }
      Text("直接发送消息即可。SideAI 会自动参考相关历史，来源显示在这次回复中，点开即可查看。").font(.callout)
      if let c = store.selected {
        Toggle("本会话使用记忆", isOn: Binding(get: { c.memoryEnabled != false }, set: { value in store.mutate(c.id) { $0.memoryEnabled = value } })).disabled(store.isBusy)
        Toggle("允许其他会话参考这条会话", isOn: Binding(get: { c.memoryExcluded != true }, set: { value in store.mutate(c.id) { $0.memoryExcluded = !value } })).disabled(store.isBusy)
      }
      if store.settings.crossConversationMemory == false { Text("全局记忆已关闭，可在设置 → 跨会话记忆开启。").font(.caption) }
      Text("相关历史摘录会随消息发送给当前 AI。关闭仅影响后续消息；已发送的内容不会被撤回。").font(.caption).foregroundStyle(.secondary)
    }.padding(16).frame(width: 340)
  }
}

struct MemorySourcesView: View {
  let memory: MemoryContext
  var openSource: (String) -> Void
  var body: some View {
    if !memory.isEmpty {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(memory.sources) { source in
            VStack(alignment: .leading, spacing: 6) {
              Button { openSource(source.id) } label: { Label(source.title, systemImage: "bubble.left") }
                .buttonStyle(.plain).font(.callout)
              Text(source.excerpt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          if !memory.notes.isEmpty { Text("记忆笔记").font(.callout); Text(memory.notes).font(.caption).textSelection(.enabled) }
        }.padding(.top, 8)
      } label: {
        Label(memory.sources.isEmpty ? "已参考记忆笔记" : "已参考 \(memory.sources.count) 条历史会话" + (memory.notes.isEmpty ? "" : "与记忆笔记"), systemImage: "brain")
          .font(.caption).foregroundStyle(.secondary)
      }.tint(.secondary)
    }
  }
}
