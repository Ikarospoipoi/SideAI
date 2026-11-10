import Foundation

public struct AppSettings: Codable {
  public var connectedRuntimes: [AccountRuntime]?
  public var connectedAgentIDs: [String]?
  public var isolatedAgentLogin: Bool?
  public var workspaceMode: WorkspaceMode?
  public var lastConversationByWorkspace: [String: UUID]?
  public var sharedMemory: String?
  public var crossConversationMemory: Bool?
  public var routingVersion: Int?
  public var chatgptHostID: String?
  public var removedAPIProfiles: [APIProfile]?
  public var claudeChatEnabled: Bool?
  public var hiddenAgentIDs: [String]?
  public var hiddenOfficialProviders: [String]?
  public var apiProfiles: [APIProfile]?
  public var selectedProfileID: UUID?
  public var defaultBackend: BackendKind?
  public var activeRoutes: [String: String]?
  public var lastConversationByRoute: [String: UUID]?
  public var claudePath: String?
  public var cliPath = ""
  public var panelOriginX: Double?
  public var panelOriginY: Double?
  public var panelWidth = 460.0
  public var screenID = ""
  public var autoPeek = true
  public var hotkeyCode: UInt32 = 49
  public var hotkeyModifiers: UInt32 = 6144  // control + option (Carbon)
  public init() {}
}
public struct Snapshot: Codable {
  public var version = 1
  public var settings: AppSettings
  public var conversations: [Conversation]
  public var selectedID: UUID?
  public init(
    settings: AppSettings = AppSettings(), conversations: [Conversation], selectedID: UUID?
  ) {
    self.settings = settings
    self.conversations = conversations
    self.selectedID = selectedID
  }
}
public struct Persistence {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  public func load() throws -> Snapshot? {
    let file = directory.appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    var snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
    guard snapshot.version == 1 else { throw ProtocolError.message("本地数据版本不兼容；原文件已保留") }
    for i in snapshot.conversations.indices where snapshot.conversations[i].status.isActive {
      snapshot.conversations[i].status = .interrupted
      snapshot.conversations[i].turnID = nil
      snapshot.conversations[i].error = "上次运行未正常结束。恢复后核对历史，不会自动重发。"
    }
    return snapshot
  }
  public func save(_ snapshot: Snapshot) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(snapshot)
    let file = directory.appendingPathComponent("state.json")
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
