import Foundation
import Security
import LocalAuthentication
import SideAICore

enum Credentials {
  private static let lock = NSLock()
  private static var cache = [UUID: String]()
  private static func cached(_ id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return cache[id] }
  private static func remember(_ value: String?, _ id: UUID) { lock.lock(); cache[id] = value; lock.unlock() }
  private static let service = "local.sideai.api-keys"
  static func read(_ id: UUID, allowInteraction: Bool = false) throws -> String? {
    if let value = cached(id) { return value }
    var query = base(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext(); context.interactionNotAllowed = !allowInteraction
    query[kSecUseAuthenticationContext as String] = context
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
    let value = String(data: data, encoding: .utf8); remember(value, id); return value
  }
  static func save(_ value: String, for id: UUID, allowInteraction: Bool = true) throws {
    let data = Data(value.utf8)
    var query = base(id)
    let context = LAContext(); context.interactionNotAllowed = !allowInteraction
    query[kSecUseAuthenticationContext as String] = context
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let inserted = SecItemAdd(query as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw failure(inserted) }
    } else if status != errSecSuccess { throw failure(status) }
    remember(value, id)
  }
  private static func base(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] }
  static func delete(_ id: UUID) throws {
    let status = SecItemDelete(base(id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    remember(nil, id)
  }
  private static func failure(_ status: OSStatus) -> ProtocolError {
    if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
      return .message("钥匙串尚未授权或授权已取消。请到「连接管理」点击「允许钥匙串访问」，或编辑连接重新保存 API Key。若 macOS 要求密码，那是系统钥匙串密码，不是模型服务的密码；消息草稿仍保留。")
    }
    return .message("钥匙串访问失败（\(status)）。密钥没有写入设置文件。")
  }
}
