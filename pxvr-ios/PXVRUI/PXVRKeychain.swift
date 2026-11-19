//
//  PXVRKeychain.swift
//  PXVRUI
//
//  账号密码存 Keychain。
//  好处：iOS 的 Keychain 条目在 App 卸载后默认仍然保留，
//  所以即使必须卸载重装，账号也能自动填回来，不用重输。
//

import Foundation
import Security

enum PXVRKeychain {

    private static let service = "com.pxvr.credentials"

    static func save(email: String, password: String) {
        set("email", email)
        set("password", password)
    }

    static func load() -> (email: String, password: String) {
        (get("email") ?? "", get("password") ?? "")
    }

    static func clear() {
        for key in ["email", "password"] { delete(key) }
    }

    // MARK: - 基础操作

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func set(_ account: String, _ value: String) {
        guard !value.isEmpty else { return }
        var q = query(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
