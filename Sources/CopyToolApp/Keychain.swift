import Foundation
import Security

enum PasswordVault {
    static let service = "local.copytool.rebuild.ftp"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ftp", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ password: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "ftp"]
        let data = Data(password.utf8)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }; return
        }
        guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
    }
}
