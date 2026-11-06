import Foundation
import CryptoKit
import SideAICore

/// Dedicated authentication directories prevent SideAI from silently importing another app's login.
enum RuntimeEnvironment {
  static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SideAI") }
  static func home(_ name: String, root: URL = Self.root) throws -> URL {
    let url = root.appendingPathComponent("Accounts/" + name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
  static func find(_ name: String) -> String? {
    var candidates = [root.appendingPathComponent("Runtimes/bin/" + name).path, root.appendingPathComponent("Runtimes/node_modules/.bin/" + name).path,
                      NSHomeDirectory() + "/.local/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
    let versions = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: NSHomeDirectory() + "/.nvm/versions/node"), includingPropertiesForKeys: nil)) ?? []
    candidates += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/" + name).path }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  static func isolated(path: String, key: String, name: String, root: URL = Self.root) throws -> [String: String] {
    var env = ClaudeCodeClient.environment(path: path)
    for key in Array(env.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key.hasPrefix("KIMI_") || key.hasPrefix("GEMINI_") || key.hasPrefix("GOOGLE_") || key.hasPrefix("GROK_") || key.hasPrefix("XAI_") || key.hasPrefix("AGY_") || key.hasPrefix("ANTIGRAVITY_") { env.removeValue(forKey: key) }
    env[key] = try home(name, root: root).path
    if name == "gemini" {
      env["ANTIGRAVITY_CREDENTIAL_SCOPE"] = "sideai-" + SHA256.hash(data: Data(env[key]!.utf8)).map { String(format: "%02x", $0) }.joined()
      env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
    }
    if let node = find("node") { env["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "") }
    env["NO_COLOR"] = "1"; env["NO_PROXY"] = "localhost,127.0.0.1,::1"
    return env
  }
  static func prepare(_ runtime: AccountRuntime, root: URL = Self.root) throws -> URL {
    let home = try home(runtime.rawValue, root: root)
    if runtime == .gemini {
      let app = home.appendingPathComponent("sideai")
      try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let settings: [String: Any] = ["toolPermission": "strict", "allowNonWorkspaceAccess": false,
        "permissions": ["deny": ["read_file(*)", "write_file(*)", "read_url(*)", "execute_url(*)", "command(*)", "mcp(*)"]]]
      try JSONSerialization.data(withJSONObject: settings).write(to: app.appendingPathComponent("settings.json"), options: .atomic)
    }
    if runtime == .kimi {
      let agents = home.appendingPathComponent("agents")
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      try "---\nname: agent\ndescription: SideAI text and image chat\noverride: true\ntools: []\nsubagents: []\n---\nYou are a helpful chat assistant. Respond to the user's messages. No local tools are available.\n".write(to: agents.appendingPathComponent("agent.md"), atomically: true, encoding: .utf8)
    }
    let cwd = root.appendingPathComponent("Scratch/Accounts/" + runtime.rawValue)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if runtime == .kimi {
      let workspaceAgents = cwd.appendingPathComponent(".kimi-code/agents")
      try FileManager.default.createDirectory(at: workspaceAgents, withIntermediateDirectories: true)
      let agent = try Data(contentsOf: home.appendingPathComponent("agents/agent.md"))
      try agent.write(to: workspaceAgents.appendingPathComponent("agent.md"), options: .atomic)
    }
    if runtime == .gemini {
      let agents = cwd.appendingPathComponent(".agents/agents")
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      try "---\nname: sideai-chat\ndescription: SideAI text and image chat\nmainAgent: true\nsubagent: false\ntools: []\nmcpServers: []\nskills: []\nplugins: []\ncommandExecutionPolicy: off\n---\nYou are a helpful chat assistant. Answer the user's message directly. No local tools are available.\n".write(to: agents.appendingPathComponent("sideai-chat.md"), atomically: true, encoding: .utf8)
    }
    return cwd
  }
  static func arguments(_ runtime: AccountRuntime, root: URL = Self.root) throws -> [String] {
    switch runtime {
    case .kimi: return ["acp"]
    case .gemini:
      let home = try home("gemini", root: root)
      return ["acp", "--gemini-dir", home.path, "--app-data-dir", "sideai",
        "--disable-telemetry", "--include-default-customizations=false", "--agent", "sideai-chat", "--log-file", "/dev/null"]
    case .grok: return ["--tools", "", "--deny", "*", "--no-subagents", "--no-plan", "--disable-web-search", "--permission-mode", "dontAsk", "agent", "stdio"]
    }
  }
}
