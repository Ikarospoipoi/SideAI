import SwiftUI
import SideAIRemote

struct RemoteHome: View {
  @ObservedObject var store: RemoteStore
  @State private var showPairing = false
  @State private var showHistory = false
  @State private var showModels = false
  @State private var showDevice = false
  @State private var selectedApproval: RemoteValue?
  var body: some View {
    NavigationStack {
      Group {
        if store.online { conversation }
        else {
          VStack(spacing: 22) {
            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 54, weight: .light)).foregroundStyle(.mint)
            Text(store.hasComputer ? "接回你的电脑" : "随时，接着做。").font(.largeTitle.bold())
            Text(store.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(store.hasComputer ? "保持电脑上的 SideAI 开启并唤醒。重连后会同步进度，不会重复发送指令。" : "在电脑启动任务，在手机继续指挥。\n发消息、换模型、查看进度、处理审批。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.hasComputer { Button("重新连接") { store.connect() }.buttonStyle(.borderedProminent); Button("管理电脑") { showDevice = true } }
            else { Button("连接我的电脑") { showPairing = true }.buttonStyle(.borderedProminent).controlSize(.large) }
          }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Color(white: 0.09))
      .navigationTitle("SideAI").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button { showHistory = true } label: { Image(systemName: "sidebar.left") }.disabled(!store.online).accessibilityLabel("会话") }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Menu { ForEach(store.routes, id: \.self) { r in Button("\(r["name"].text) · \(r["workspace"].text == "agent" ? "Agent" : "聊天")") { store.command("new", fields: ["route": r["id"]]) } } } label: { Image(systemName: "square.and.pencil") }.disabled(!store.online || store.pending || store.state["busy"].bool).accessibilityLabel("新建会话")
          Button { showDevice = true } label: { Image(systemName: "laptopcomputer") }.accessibilityLabel("电脑连接")
        }
      }
      .sheet(isPresented: $showPairing) { PairingView(store: store) }
      .sheet(isPresented: $showModels) { RemoteModelView(store: store) }
      .sheet(isPresented: $showHistory) { history }
      .sheet(isPresented: $showDevice) { device }
      .sheet(isPresented: Binding(get: { selectedApproval != nil }, set: { if !$0 { selectedApproval = nil } })) {
        if let approval = selectedApproval { RemoteApprovalView(store: store, approval: approval) }
      }
      .alert("SideAI", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }
  }
  private var conversation: some View {
    VStack(spacing: 0) {
      HStack {
        Menu {
          ForEach(store.routes, id: \.self) { route in
            Button(route["name"].text) {
              if let c = store.state["conversations"].array.first(where: { $0["route"] == route["id"] }) { store.command("watch", fields: ["conversation": c["id"]]) }
              else { store.command("new", fields: ["route": route["id"]]) }
            }
          }
        } label: { Label(store.routes.first(where: { $0["id"] == store.current["route"] })?["name"].text ?? "选择 AI", systemImage: "arrow.triangle.swap") }.disabled(store.pending)
        Spacer()
        Text(store.current["status"].text).font(.caption).foregroundStyle(.secondary)
      }.padding(.horizontal, 18).padding(.vertical, 12)
      if !store.current["title"].text.isEmpty { Text(store.current["title"].text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 10) }
      if !store.approvals.isEmpty {
        VStack(spacing: 8) {
          ForEach(store.approvals, id: \.self) { request in
            Button { selectedApproval = request } label: { HStack { Image(systemName: "hand.raised"); Text(request["title"].text); Spacer(); Image(systemName: "chevron.right") }.font(.callout).padding(14).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)) }.foregroundStyle(.orange)
          }
        }.padding(.horizontal, 16).padding(.bottom, 10)
      }
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            if store.current["items"].array.isEmpty { Text("从这里发出下一步指令。\n电脑上的 Agent 会继续执行。").font(.title3).foregroundStyle(.secondary).padding(.top, 45) }
            if store.current["historyLimited"].bool { Text("更早的记录请在电脑查看。").font(.caption).foregroundStyle(.secondary) }
            ForEach(store.current["items"].array, id: \.self) { item in
              if !item["text"].text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  Text(item["role"].text == "userMessage" ? "你" : item["role"].text == "agentMessage" ? "AI" : "操作与进度").font(.caption2).foregroundStyle(.secondary)
                  Text(item["text"].text).textSelection(.enabled).font(.system(size: 15)).lineSpacing(4)
                  if item["truncated"].bool { Text("长内容已截取，请在电脑查看完整记录。").font(.caption).foregroundStyle(.secondary) }
                }.padding(item["role"].text == "userMessage" ? 14 : 0).frame(maxWidth: .infinity, alignment: .leading)
                  .background(item["role"].text == "userMessage" ? Color(white: 0.18) : .clear, in: RoundedRectangle(cornerRadius: 16))
              }
            }
            if !store.current["error"].text.isEmpty { Text(store.current["error"].text).font(.caption).foregroundStyle(.orange) }
            if store.current["active"].bool { HStack { ProgressView(); Text("电脑正在执行…").font(.caption).foregroundStyle(.secondary) } }
            Color.clear.frame(height: 1).id("bottom")
          }.padding(18)
        }.overlay(alignment: .bottomTrailing) { Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: { Image(systemName: "arrow.down").padding(10).background(.ultraThinMaterial, in: Circle()) }.padding(10).accessibilityLabel("最新消息") }
          .onChange(of: store.current["id"]) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
      }
      HStack {
        Button { showModels = true } label: { HStack { Image(systemName: "slider.horizontal.3"); Text(store.current["model"].text.isEmpty ? "模型与项目" : store.current["model"].text).lineLimit(1) }.font(.caption) }.disabled(store.current == .null)
        Spacer()
        Text("在电脑上执行").font(.caption2).foregroundStyle(.secondary)
      }.padding(.horizontal, 18).padding(.vertical, 10)
      HStack(alignment: .bottom, spacing: 10) {
        TextField("下一步要做什么？", text: $store.draft, axis: .vertical).lineLimit(1...5).padding(12).background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("消息输入框")
        if store.current["active"].bool {
          Button { store.command("stop") } label: { Image(systemName: "stop.fill").frame(width: 42, height: 42).background(Color(white: 0.24), in: Circle()) }.disabled(store.pending).accessibilityLabel("停止任务")
        } else {
          Button { store.command("send", fields: ["text": .string(store.draft)]) } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 42, height: 42).background(.mint, in: Circle()).foregroundStyle(.black) }.disabled(store.pending || store.state["busy"].bool || store.current == .null || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送消息")
        }
      }.padding(.horizontal, 16).padding(.bottom, 12)
    }
  }
  private var history: some View {
    NavigationStack {
      List(store.state["conversations"].array, id: \.self) { c in Button { store.command("watch", fields: ["conversation": c["id"]]); showHistory = false } label: { VStack(alignment: .leading, spacing: 5) { Text(c["title"].text); Text(c["status"].text).font(.caption).foregroundStyle(.secondary) } } }
        .navigationTitle("电脑上的会话").toolbar { Button("完成") { showHistory = false } }
    }
  }
  private var device: some View {
    NavigationStack {
      Form {
        Section("当前电脑") { Text(store.configuration?.pairing.name ?? store.state["host"].text); Text(store.status).foregroundStyle(.secondary); Button("重新连接") { store.connect(); showDevice = false } }
        Section { Text("手机退到后台后连接可能暂停，Agent 仍在电脑继续。回到手机会同步最新进度。此版本不提供后台推送通知。").font(.caption) }
        Section { Button("移除手机上的配对", role: .destructive) { store.unpair(); showDevice = false }; Text("如要撤销遥控权限，也可在电脑的手机遥控设置中解除配对。").font(.caption) }
      }.navigationTitle("电脑连接").toolbar { Button("完成") { showDevice = false } }
    }
  }
}

extension RemoteValue: @retroactive Hashable {
  public func hash(into hasher: inout Hasher) { hasher.combine(pretty) }
}
