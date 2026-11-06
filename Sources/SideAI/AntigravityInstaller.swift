import Foundation
import CryptoKit
import SideAICore

/// Installs the unmodified official binary into SideAI, without changing shell profiles.
enum AntigravityInstaller {
  static func install(using runner: LoginProcess) async throws -> String {
    let fm = FileManager.default
    let staging = fm.temporaryDirectory.appendingPathComponent("SideAI-install-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: staging) }
    #if arch(arm64)
    let platform = "darwin_arm64"
    #else
    let platform = "darwin_amd64"
    #endif
    let manifest = staging.appendingPathComponent("manifest.json"), archive = staging.appendingPathComponent("release.tar.gz")
    let environment = ClaudeCodeClient.environment(path: "/usr/bin/curl")
    func download(_ url: String, to file: URL) async throws {
      try await runner.run(path: "/usr/bin/curl", arguments: ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "180", url, "--output", file.path], environment: environment, cwd: staging)
    }
    try await download("https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/" + platform + ".json", to: manifest)
    let data = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: manifest))
    guard let url = URL(string: data["url"].text), url.scheme == "https", url.host == "storage.googleapis.com",
          url.path.hasPrefix("/antigravity-public/antigravity-cli/"), url.path.hasSuffix(".tar.gz"),
          data["sha512"].text.range(of: "^[0-9a-f]{128}$", options: .regularExpression) != nil else { throw ProtocolError.message("官方客户端下载信息无效。") }
    try await download(url.absoluteString, to: archive)
    let checksum = try await Task.detached { SHA512.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined() }.value
    guard checksum == data["sha512"].text else { throw ProtocolError.message("客户端下载校验失败，请重试。") }
    try Task.checkCancellation()
    try await runner.run(path: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", staging.path, "antigravity"], environment: environment, cwd: staging)
    let destination = RuntimeEnvironment.root.appendingPathComponent("Runtimes/bin")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let executable = destination.appendingPathComponent("agy")
    try fm.moveItem(at: staging.appendingPathComponent("antigravity"), to: executable)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable.path
  }
}
