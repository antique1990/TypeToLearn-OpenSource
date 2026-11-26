import Foundation
import Security

enum MacKeychain {
    private static let service = "com.learnkeyboard.mac.debug.siliconflow"
    private static let account = "user-api-key"
    static var inputMethodURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/TypeToLearnInputMethod.app")
    }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load(interactive: Bool = false) throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeychainError(status: errSecParam) }
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                       kSecAttrLabel as String: "伴语 Mac · 硅基流动 API Key"]
        // The two native Debug apps share one login-Keychain item, not a plaintext settings file.
        var trusted: [SecTrustedApplication] = []
        var own: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &own) == errSecSuccess, let own { trusted.append(own) }
        if FileManager.default.fileExists(atPath: inputMethodURL.path) {
            var inputMethod: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(inputMethodURL.path, &inputMethod) == errSecSuccess,
               let inputMethod { trusted.append(inputMethod) }
        }
        var access: SecAccess?
        if SecAccessCreate("伴语 Mac 翻译" as CFString, trusted as CFArray, &access) == errSecSuccess, let access {
            attributes[kSecAttrAccess as String] = access
        }
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "无法访问钥匙串（\(status)）。请安装输入法后，在伴语设置中重新保存 API Key 并允许钥匙串访问。"
        }
    }
}
