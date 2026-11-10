import SwiftUI
import AVFoundation
import VisionKit

struct PairingView: View {
  @ObservedObject var store: RemoteStore
  var initialURL = ""
  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var scanning = false
  @State private var cameraError = ""
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("在电脑的 SideAI 设置中打开「手机遥控」，生成配对二维码。", systemImage: "laptopcomputer")
          Button { Task { await scan() } } label: { Label("扫描电脑上的二维码", systemImage: "qrcode.viewfinder") }
          if !cameraError.isEmpty { Text(cameraError).foregroundStyle(.orange) }
        }
        Section("也可以粘贴配对链接") {
          TextField("sideai://pair#…", text: $link, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("连接电脑") { connect() }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section { Text("配对后还需在电脑上确认一次。二维码包含遥控凭证，请勿分享给他人；10 分钟内有效。AI 账号密钥保留在电脑上。") }
      }
      .navigationTitle("连接电脑").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
      .onAppear { link = initialURL }
      .alert("无法配对", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
      .sheet(isPresented: $scanning) { QRScanner { value in scanning = false; link = value } .ignoresSafeArea().overlay(alignment: .topTrailing) { Button("关闭") { scanning = false }.padding().background(.ultraThinMaterial, in: Capsule()).padding() } }
    }
  }
  private func connect() { store.pair(link); if store.error == nil { dismiss() } }
  private func scan() async {
    guard DataScannerViewController.isSupported else { cameraError = "此设备不支持扫码，请粘贴电脑上的配对链接。"; return }
    let allowed = await AVCaptureDevice.requestAccess(for: .video)
    guard allowed, DataScannerViewController.isAvailable else { cameraError = "请在 iPhone 设置中允许相机，或直接粘贴配对链接。"; return }
    scanning = true
  }
}

struct QRScanner: UIViewControllerRepresentable {
  var found: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(found: found) }
  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    try? scanner.startScanning()
    return scanner
  }
  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (String) -> Void
    private var completed = false
    init(found: @escaping (String) -> Void) { self.found = found }
    func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      for item in addedItems {
        if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, value.hasPrefix("sideai://pair#"), !completed {
          completed = true; scanner.stopScanning(); found(value)
        }
      }
    }
  }
}
