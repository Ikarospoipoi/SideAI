import SwiftUI
import SideAIRemote

struct RemoteModelView: View {
  @ObservedObject var store: RemoteStore
  @Environment(\.dismiss) private var dismiss
  @State private var model = ""
  @State private var effort = ""
  @State private var cwd = ""
  @State private var mode = "readOnly"
  private var route: RemoteValue { store.routes.first { $0["id"] == store.current["route"] } ?? .null }
  var body: some View {
    NavigationStack {
      Form {
        Section("模型") {
          ForEach(route["models"].array, id: \.self) { option in Button { model = option["id"].text; effort = "" } label: { HStack { Text(option["name"].text); Spacer(); if model == option["id"].text { Image(systemName: "checkmark") } } } }
          TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("刷新模型／电脑连接") { store.command("models") }.disabled(store.pending || store.state["busy"].bool)
        }
        Section("推理强度") {
          Picker("强度", selection: $effort) { Text("默认").tag(""); ForEach(route["models"].array.first(where: { $0["id"].text == model })?["efforts"].array.map(\.text) ?? ["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) } }
        }
        if route["workspace"].text == "agent" {
          Section("项目与权限") {
            Picker("项目", selection: $cwd) { ForEach(store.state["projects"].array, id: \.self) { p in Text(p["name"].text).tag(p["path"].text) } }
            Picker("权限", selection: $mode) { Text("只读 Agent").tag("readOnly"); Text("项目 Agent").tag("project") }
            Text("只能选择电脑上已有的项目；写入仍按 Agent 的审批流程确认。").font(.caption).foregroundStyle(.secondary)
          }
        }
        Section { Text("设置用于下一轮请求。正在执行的任务不会中途更换模型。").font(.caption).foregroundStyle(.secondary) }
      }.navigationTitle("模型与项目").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { store.command("configure", fields: ["model": .string(model), "effort": .string(effort), "cwd": .string(cwd), "mode": .string(mode)]); dismiss() }.disabled(store.pending || !store.online || store.state["busy"].bool || model.isEmpty) } }
    }.onAppear { model = store.current["model"].text; effort = store.current["effort"].text; cwd = store.current["cwd"].text; mode = store.current["mode"].text }
  }
}
