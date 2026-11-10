import Foundation
import Security

public enum RemoteVault {
  public static func read(_ account: String) throws -> Data? {
    var query = base(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw RemoteError.message("无法读取设备配对，请检查系统钥匙串权限。") }
    return result as? Data
  }
  public static func save(_ data: Data, account: String) throws {
    var query = base(account)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw RemoteError.message("无法保存设备配对") }
    } else if status != errSecSuccess { throw RemoteError.message("无法更新设备配对") }
  }
  public static func delete(_ account: String) throws {
    let status = SecItemDelete(base(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteError.message("无法移除设备配对") }
  }
  private static func base(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.sideai.remote", kSecAttrAccount as String: account] }
}
