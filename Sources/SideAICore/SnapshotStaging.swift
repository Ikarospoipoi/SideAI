import Foundation
import Darwin

/// Encode and stage off the main actor. Only the caller may commit a still-current generation.
public enum SnapshotStaging {
  public static func stage(_ snapshot: Snapshot, directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(".snapshot-" + UUID().uuidString + ".tmp")
    do {
      try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return url
    } catch { try? FileManager.default.removeItem(at: url); throw error }
  }
  public static func commit(_ staged: URL, directory: URL) throws {
    let target = directory.appendingPathComponent("state.json")
    guard rename(staged.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  }
}

public actor SnapshotStagingQueue {
  public init() {}
  public func stage(_ snapshot: Snapshot, directory: URL) throws -> URL {
    try Task.checkCancellation()
    return try SnapshotStaging.stage(snapshot, directory: directory)
  }
}
