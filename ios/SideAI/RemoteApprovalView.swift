import SwiftUI
import SideAIRemote

struct RemoteApprovalView: View {
  @ObservedObject var store: RemoteStore
  let approval: RemoteValue
  @Environment(\.dismiss) private var dismiss
  @State private var answers: [String: String] = [:]
  @State private var confirming = false
  private var live: Bool { store.online && store.approvals.contains { $0["id"] == approval["id"] && $0["fingerprint"] == approval["fingerprint"] } }
  var body: some View {
    NavigationStack {
      Form {
        Section { Text(approval["title"].text).font(.headline); Text(approval["cwd"].text).font(.caption).textSelection(.enabled) }
        Section("请求详情") { Text(approval["detail"].text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        ForEach(approval["questions"].array, id: \.self) { q in
          Section(q["question"].text) {
            ForEach(q["options"].array, id: \.self) { option in
              Button { answers[q["id"].text] = option["label"].text } label: {
                VStack(alignment: .leading) { Text(option["label"].text); Text(option["description"].text).font(.caption).foregroundStyle(.secondary) }
              }
            }
            TextField("你的回答", text: Binding(get: { answers[q["id"].text] ?? "" }, set: { answers[q["id"].text] = $0 }), axis: .vertical)
          }
        }
        if !approval["canApprove"].bool { Text("请求详情过长，请在电脑上完整查看并处理。手机仍可拒绝或停止任务。").foregroundStyle(.orange) }
        if !live { Text("此请求已处理、已改变或电脑已离线，请返回刷新。").foregroundStyle(.orange) }
        Section {
          Button(approval["questions"].array.isEmpty ? "允许此次操作" : "提交回答") { confirming = true }
            .disabled(!live || store.pending || !approval["canApprove"].bool || approval["questions"].array.contains { (answers[$0["id"].text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
          if approval["questions"].array.isEmpty { Button("拒绝", role: .destructive) { respond(false) }.disabled(!live || store.pending) }
          Button("停止此任务", role: .destructive) { store.command("stop", fields: ["conversation": approval["conversation"]]); dismiss() }.disabled(!live || store.pending)
        }
      }
      .navigationTitle("需要你确认").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
      .confirmationDialog("将由电脑执行这次批准的操作", isPresented: $confirming, titleVisibility: .visible) { Button("确认") { respond(true) } }
    }
  }
  private func respond(_ allow: Bool) {
    store.command("approve", fields: ["approval": approval["id"], "fingerprint": approval["fingerprint"], "allow": .bool(allow), "answers": .object(answers.mapValues(RemoteValue.string))]); dismiss()
  }
}
