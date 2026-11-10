import XCTest
import AppKit
@testable import SideAI
import SideAICore

final class TransportTests: XCTestCase {
  var server: Process!
  var port = ""
  override func setUpWithError() throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/api_fixture.py")
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", script.path]
    let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    var bytes = Data()
    while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data([10]) { break }; bytes.append(byte) }
    port = String(decoding: bytes, as: UTF8.self)
    XCTAssertFalse(port.isEmpty)
  }
  override func tearDown() { if server.isRunning { server.terminate(); server.waitUntilExit() } }
  func profile(_ route: String = "v1", format: APIFormat = .responses) -> APIProfile {
    var p = APIProfile(); p.baseURL = "http://127.0.0.1:\(port)/\(route)"; p.format = format; return p
  }
  func testAllHTTPStreamingAdaptersAndModelDiscovery() async throws {
    for format in APIFormat.allCases {
      let client = HTTPChatClient(); defer { client.cancel() }
      let p = profile(format: format)
      let models = try await client.models(profile: p, key: "fixture-key")
      XCTAssertEqual(models.map(\.id), ["fixture-vision"])
      let text = try await client.stream(profile: p, key: "fixture-key", body: .object(["model": .string("fixture-vision")])) { _ in }
      XCTAssertEqual(text, "你好🌿")
    }
  }
  func testRedirectTruncationAndCredentialRedaction() async throws {
    for format in APIFormat.allCases {
    for route in ["redirect", "unauthorized", "truncated"] {
      let client = HTTPChatClient(); defer { client.cancel() }
      do {
        _ = try await client.stream(profile: profile(route, format: format), key: "fixture-key", body: .object(["model": .string("fixture-vision")])) { _ in }
        XCTFail("Expected failure for \(route)")
      } catch { XCTAssertFalse(error.localizedDescription.contains("fixture-key")) }
    }
  }
  }
  func testQuotaStreamDiagnosticUsesRealHTTPStatusAndRedactsCredential() async throws {
    let client = HTTPChatClient(); defer { client.cancel() }
    do {
      _ = try await client.stream(profile: profile("quota"), key: "fixture-key", body: .object(["model": .string("fixture-vision")])) { _ in }
      XCTFail("Expected stream error")
    } catch let error as HTTPChatFailure {
      XCTAssertEqual(error.diagnostic.status, 200)
      XCTAssertEqual(error.diagnostic.event, "error")
      XCTAssertEqual(error.diagnostic.errorType, "invalid_request_error")
      XCTAssertEqual(error.diagnostic.errorCode, "subscription_sharing_usage_limit_exceeded")
      XCTAssertTrue(error.diagnostic.resetFields.isEmpty)
      XCTAssertFalse(error.localizedDescription.contains("fixture-key"))
    }
  }
  func testCancelHTTPStream() async throws {
    let client = HTTPChatClient(), p = profile("slow")
    let task = Task { try await client.stream(profile: p, key: "fixture-key", body: .object(["model": .string("fixture-vision")])) { _ in } }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel(); client.cancel()
    do { _ = try await task.value; XCTFail("Cancellation should not complete") } catch { }
  }
  func testCancelledClientNeverCreatesTaskOnInvalidatedSession() async throws {
    let client = HTTPChatClient(); client.cancel()
    do {
      _ = try await client.stream(profile: profile(format: .chatCompletions), key: "fixture-key", body: .object([:])) { _ in }
      XCTFail("Cancelled client must reject streaming")
    } catch { XCTAssertTrue(error is CancellationError) }
    do { _ = try await client.models(profile: profile(), key: "fixture-key"); XCTFail("Cancelled client must reject models") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
  func testCancellationRacingRequestStartupAndClientOnlyCancellation() async throws {
    for _ in 0..<30 {
      let client = HTTPChatClient(), p = profile("slow", format: .chatCompletions)
      let task = Task { try await client.stream(profile: p, key: "fixture-key", body: .object([:])) { _ in } }
      await Task.yield(); client.cancel()
      do { _ = try await task.value; XCTFail("Cancelled request must not succeed") } catch { }
    }
    let client = HTTPChatClient(), p = profile("slow")
    let task = Task { try await client.stream(profile: p, key: "fixture-key", body: .object([:])) { _ in } }
    try await Task.sleep(nanoseconds: 100_000_000); client.cancel()
    do { _ = try await task.value; XCTFail("Client cancellation must stop active request") } catch { }
  }
  @MainActor func testComposerAcceptsFileAndBitmapPasteboardWithoutInsertingPaths() throws {
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let editor = ComposerTextView(); editor.string = "保留原有文字"
    var urls = [URL](); var bitmap: Data?
    editor.imageFiles = { urls = $0 }; editor.imageData = { bitmap = $0 }
    let file = URL(fileURLWithPath: "/tmp/sideai-test.png")
    board.writeObjects([file as NSURL])
    XCTAssertTrue(editor.accept(board)); XCTAssertEqual(urls, [file])
    XCTAssertEqual(editor.string, "保留原有文字")
    board.clearContents(); board.setData(Data([1,2,3]), forType: .png)
    XCTAssertTrue(editor.accept(board)); XCTAssertEqual(bitmap, Data([1,2,3]))
    board.clearContents(); board.setString("普通文字", forType: .string)
    XCTAssertFalse(editor.accept(board))
  }
  func testAttachmentCopiesTemporaryImageAndNormalizesIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let library = AttachmentLibrary(directory: dir)
    let attachment = try library.importData(source.representation(using: .png, properties: [:])!)
    let result = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: attachment.path)))!
    XCTAssertEqual(result.pixelsWide, 2048)
    XCTAssertTrue(try attachment.dataURL().hasPrefix("data:image/png;base64,"))
    XCTAssertThrowsError(try library.importData(Data("/tmp/not-an-image.png".utf8)))
  }
}
