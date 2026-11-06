import AppKit
import ImageIO
import SideAICore
import UniformTypeIdentifiers

struct AttachmentLibrary {
  let directory: URL
  func importFile(_ url: URL) throws -> ImageAttachment {
    guard url.isFileURL else { throw ProtocolError.message("仅支持本地图片文件") }
    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 20 * 1024 * 1024 else { throw ProtocolError.message("图片需要小于 20 MB") }
    return try importData(Data(contentsOf: url), name: url.lastPathComponent)
  }
  func importData(_ data: Data, name: String = "粘贴的图片") throws -> ImageAttachment {
    guard data.count <= 20 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048,
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else { throw ProtocolError.message("无法读取图片。支持 PNG、JPEG、WebP、HEIC、GIF 首帧，最大 20 MB。") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let id = UUID(), url = directory.appendingPathComponent(UUID().uuidString + ".png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ProtocolError.message("无法保存附件") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ProtocolError.message("附件保存失败") }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return ImageAttachment(id: id, path: url.path, name: name)
  }
}

extension SessionStore {
  var attachmentLibrary: AttachmentLibrary { AttachmentLibrary(directory: persistence.directory.appendingPathComponent("Attachments", isDirectory: true)) }
  func addImageURLs(_ urls: [URL], to id: UUID) {
    for url in urls {
      guard let c = state.conversations.first(where: { $0.id == id }), c.images.count < 8 else { banner = "每条消息最多附加 8 张图片"; return }
      do { let image = try attachmentLibrary.importFile(url); mutate(id) { $0.attachments = $0.images + [image] } }
      catch { banner = error.localizedDescription }
    }
  }
  func addImageData(_ data: Data, to id: UUID) {
    guard let c = state.conversations.first(where: { $0.id == id }), c.images.count < 8 else { banner = "每条消息最多附加 8 张图片"; return }
    do { let image = try attachmentLibrary.importData(data); mutate(id) { $0.attachments = $0.images + [image] } }
    catch { banner = error.localizedDescription }
  }
  func chooseImages() {
    guard let id = selectedID else { return }
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.prompt = "附加图片"
    if panel.runModal() == .OK { addImageURLs(panel.urls, to: id) }
  }
}
