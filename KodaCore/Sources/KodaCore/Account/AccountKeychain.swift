#if canImport(Security)
import Foundation
import Security

/// Each signed-in profile's YouTube cookies in the Keychain, one item per profile,
/// readable after first unlock on this device only and never synced. Where the Keychain
/// refuses (an unsigned Mac build has no access group), a file only this user can read
/// stands in, as it does for Last.fm.
public struct AccountKeychain: AccountCookieStore {
    public enum Read: Sendable, Equatable {
        case found(YouTubeCookies)
        /// Nothing saved: never signed in, or signed out.
        case missing
        /// Something is saved but can't be read right now (the device is locked, or Koda
        /// started in the background before the first unlock). That is not signed out:
        /// keep the profile signed in and read again later, and write nothing over it.
        case unreadable
    }

    public let service: String
    let directory: URL

    /// - Parameter directory: where the stand-in files go when the Keychain refuses.
    public init(service: String = "ivors.Koda.youtube", directory: URL) {
        self.service = service
        self.directory = directory
    }

    public func read(_ profileID: UUID) -> Read {
        var query = query(profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let cookies = try? JSONDecoder().decode(YouTubeCookies.self, from: data) {
            return .found(cookies)
        }
        if let data = try? Data(contentsOf: fallback(profileID)), let cookies = try? JSONDecoder().decode(YouTubeCookies.self, from: data) {
            return .found(cookies)
        }
        // Not found, or no Keychain at all for this build (the file above stands in for
        // it): nothing is saved. Anything else is the Keychain saying "not now".
        return status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecSuccess ? .missing : .unreadable
    }

    public func save(_ cookies: YouTubeCookies, for profileID: UUID) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        let query = query(profileID)
        // Update in place first: deleting and re-adding would leave a moment with nothing
        // saved, and a locked Keychain refuses both halves anyway.
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            try? FileManager.default.removeItem(at: fallback(profileID))
            return
        }
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
                try? FileManager.default.removeItem(at: fallback(profileID))
                return
            }
        }
        // Locked rather than missing: the saved item is still there and still good, and
        // the next rotation will try again. Only a build without a Keychain uses the file.
        guard update == errSecItemNotFound || update == errSecMissingEntitlement else { return }
        writeFallback(data, profileID)
    }

    public func delete(_ profileID: UUID) {
        SecItemDelete(query(profileID) as CFDictionary)
        try? FileManager.default.removeItem(at: fallback(profileID))
    }

    private func query(_ profileID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: profileID.uuidString]
    }

    private func fallback(_ profileID: UUID) -> URL {
        directory.appending(path: "youtube-\(profileID.uuidString).json")
    }

    private func writeFallback(_ data: Data, _ profileID: UUID) {
        let url = fallback(profileID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
    }
}
#endif
