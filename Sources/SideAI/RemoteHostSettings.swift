import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteHostSettings: View {
  @ObservedObject var host: RemoteHost
  @State private var relay = ""
  @State private var confirmRevoke = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("用 iPhone，接着做。 ").font(.title2.bold())
        Text("电脑负责运行 Agent，手机可以发消息、选模型、查看进度和审批操作。两端需要联网，电脑需要保持唤醒。").foregroundStyle(.secondary)
        Label(host.status, systemImage: host.enabled ? "antenna.radiowaves.left.and.right" : "iphone")
        if let config = host.configuration, let device = config.deviceName {
          Label(device, systemImage: "iphone")
          Text("此手机可以查看会话，并代表你指挥与审批 Agent。AI 账号密钥仍保存在电脑上。").font(.caption).foregroundStyle(.secondary)
          HStack {
            Button(host.enabled ? "暂停遥控" : "恢复遥控") { host.enabled ? host.pause() : host.start() }
            Button("解除手机配对", role: .destructive) { confirmRevoke = true }
          }
        } else {
          TextField("wss://你的中继域名/v1/connect", text: $relay).textFieldStyle(.roundedBorder)
          Button(host.configuration == nil ? "生成配对二维码" : "重新生成二维码") { host.create(relay: relay) }
          if let config = host.configuration {
            if let image = qr(config.pairing.link) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 230, height: 230).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 12)) }
            Text("在 iPhone 的 SideAI 中扫描。二维码 10 分钟内有效，请勿转发或截图分享。").font(.caption).foregroundStyle(.secondary)
            Button("复制配对链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.pairing.link, forType: .string) }
          }
          if let pending = host.pendingDevice {
            VStack(alignment: .leading, spacing: 10) {
              Text("\(pending.name) 请求遥控这台电脑").font(.headline)
              Text("允许后，手机可查看对话、发送指令和审批工具操作。").font(.caption)
              HStack { Button("允许这台手机") { host.approveDevice() }; Button("拒绝并失效二维码") { host.revoke() } }
            }.padding().background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
          }
        }
        Divider()
        Text("异地访问通过你部署的中继转发，消息在设备之间加密。中继不保存聊天记录。暂停或解除配对立即停止远程指令；已经运行的任务仍在电脑继续。").font(.caption).foregroundStyle(.secondary)
      }.padding(22)
    }.onAppear { relay = host.configuration?.pairing.relay ?? "" }
      .confirmationDialog("解除这台手机的远程控制权限？", isPresented: $confirmRevoke) { Button("解除配对", role: .destructive) { host.revoke() } }
  }
  private func qr(_ text: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator(); f.message = Data(text.utf8)
    guard let image = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}
