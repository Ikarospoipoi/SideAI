import Foundation
import PDFKit
import SideAICore

enum DocumentAttachment {
  static func read(_ url: URL) throws -> String {
    guard url.pathExtension.lowercased() == "pdf" else { return try TextAttachment.read(url) }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 20_000_000 else { throw ProtocolError.message("PDF 不能超过 20 MB。") }
    guard let document = PDFDocument(url: url), !document.isLocked else { throw ProtocolError.message("PDF 无法读取或已加密，请先解锁文件。") }
    guard document.pageCount <= 300 else { throw ProtocolError.message("PDF 超过 300 页，请先拆分后导入。") }
    var pages: [String] = [], sizeRead = 0
    for index in 0..<document.pageCount {
      let text = document.page(at: index)?.string ?? ""
      sizeRead += text.utf8.count
      guard sizeRead <= 1_000_000 else { throw ProtocolError.message("提取文本超过 1 MB，请拆分 PDF 后导入。") }
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append("[第 \(index + 1) 页]\n" + text) }
    }
    guard !pages.isEmpty else { throw ProtocolError.message("PDF 没有可提取文本，可能是扫描件。请先 OCR 或使用截图图片输入。") }
    return "文件：\(url.lastPathComponent)\nPDF 文本提取：不包含图片，表格与阅读顺序请核对原文。\n\n" + pages.joined(separator: "\n\n")
  }
}
