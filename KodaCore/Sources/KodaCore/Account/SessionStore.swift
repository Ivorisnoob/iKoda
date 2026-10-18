import Foundation
import Security

/// The YouTube session cookie string in the Keychain, readable on this device

/// The YouTube session cookie string in the Keychain, readable on this device
/// only and never synced. Where the Keychain refuses (an unsigned Mac build
/// has no access group), a file only this user can read stands in, so an
/// account still works rather than failing to open. Same arrangement as the
/// Last.fm credentials: unreadable is *not* signed out.
struct SessionStore {
    let service: String
    let fallback: URL
    private let account = "authentication"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum Read {
        case found(String)
        /// Nothing saved: never signed in, or signed out.
        case missing
        /// Something is saved but cannot be read right now (the device is locked).
        case unreadable
    }

    func read() -> Read {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let string = String(data: data, encoding: .utf8) {
            return .found(string)
        }
        if let data = try? Data(contentsOf: fallback), let string = String(data: data, encoding: .utf8) {
            return .found(string)
        }
        // Not found, or no Keychain at all for this build (the file above
        // stands in for it): nothing is saved. Anything else is the Keychain
        // saying "not now".
        return status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecSuccess ? .missing : .unreadable
    }

    func write(_ cookieString: String) {
        guard let data = cookieString.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallback)
            return
        }
        try? data.write(to: fallback, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fallback
        try? url.setResourceValues(values)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallback)
    }
}
