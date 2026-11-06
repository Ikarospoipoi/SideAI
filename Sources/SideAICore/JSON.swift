import Foundation

public enum JSON: Codable, Equatable, Sendable {
  case object([String: JSON])
  case array([JSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let x = try? c.decode(Bool.self) {
      self = .bool(x)
    } else if let x = try? c.decode(Double.self) {
      self = .number(x)
    } else if let x = try? c.decode(String.self) {
      self = .string(x)
    } else if let x = try? c.decode([JSON].self) {
      self = .array(x)
    } else {
      self = .object(try c.decode([String: JSON].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let x): try c.encode(x)
    case .array(let x): try c.encode(x)
    case .string(let x): try c.encode(x)
    case .number(let x): try c.encode(x)
    case .bool(let x): try c.encode(x)
    case .null: try c.encodeNil()
    }
  }
  public subscript(_ key: String) -> JSON {
    if case .object(let x) = self { return x[key] ?? .null }
    return .null
  }
  public var string: String? {
    if case .string(let x) = self { return x }
    return nil
  }
  public var text: String { string ?? "" }
  public var array: [JSON] {
    if case .array(let x) = self { return x }
    return []
  }
  public var bool: Bool {
    if case .bool(let x) = self { return x }
    return false
  }
  public var pretty: String {
    guard let d = try? JSONEncoder.pretty.encode(self) else { return "" }
    return String(decoding: d, as: UTF8.self)
  }
  public var key: String {
    switch self {
    case .string(let s): return "s:" + s
    case .number(let n): return "n:\(n)"
    default: return "invalid"
    }
  }
}
extension JSONEncoder {
  static var pretty: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
  }
}

/// Newline framing operates on bytes so a split UTF-8 character is never decoded prematurely.
public struct JSONLineFramer {
  private var buffer = Data()
  public init() {}
  public mutating func append(_ data: Data) throws -> [JSON] {
    buffer.append(data)
    guard buffer.count < 32 * 1024 * 1024 else { throw ProtocolError.message("后端输出单帧超过 32 MB") }
    var messages = [JSON]()
    while let end = buffer.firstIndex(of: 10) {
      let line = buffer[..<end]
      buffer.removeSubrange(...end)
      if !line.isEmpty { messages.append(try JSONDecoder().decode(JSON.self, from: line)) }
    }
    return messages
  }
}
public enum ProtocolError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let s): return s
    }
  }
}
