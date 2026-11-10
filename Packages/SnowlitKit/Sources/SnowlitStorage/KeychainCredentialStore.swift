#if canImport(Security)
import Foundation
import Security
import SnowlitCore

/// Serializes synchronous Keychain calls away from the main actor. Each source
/// installation has its own service; records are never written to SQLite/files.
public actor KeychainCredentialStore: CredentialStore {
    private let servicePrefix: String

    public init(servicePrefix: String = "io.github.bemarkt.snowlit.credentials") throws {
        guard !servicePrefix.isEmpty, !servicePrefix.utf8.contains(0) else { throw CredentialStoreFailure.invalidData }
        self.servicePrefix = servicePrefix
    }

    public func read(_ id: StoredCredentialID) throws -> CredentialSecret? {
        try Task.checkCancellation()
        var query = query(for: id.installationID, id: id.id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let value = result as? Data else { throw CredentialStoreFailure.invalidData }
        return CredentialSecret(bytes: value)
    }

    public func write(_ value: CredentialSecret, for id: StoredCredentialID) throws {
        try Task.checkCancellation()
        let query = query(for: id.installationID, id: id.id)
        let attributes: [String: Any] = [
            kSecValueData as String: value.bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, value in value }
            // Do not delete/re-add existing items or hide a concurrent duplicate.
            try check(SecItemAdd(insertion as CFDictionary, nil))
        } else { try check(status) }
    }

    public func remove(_ id: StoredCredentialID) throws {
        try Task.checkCancellation()
        try checkRemoval(SecItemDelete(query(for: id.installationID, id: id.id) as CFDictionary))
    }

    public func removeAll(for installationID: SourceInstallationID) throws {
        try Task.checkCancellation()
        try checkRemoval(SecItemDelete(query(for: installationID) as CFDictionary))
    }

    private func query(for installationID: SourceInstallationID, id: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + "." + installationID.rawValue.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false
        ]
        if let id { query[kSecAttrAccount as String] = id.uuidString.lowercased() }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialStoreFailure.systemStatus(status) }
    }

    private func checkRemoval(_ status: OSStatus) throws {
        if status != errSecItemNotFound { try check(status) }
    }
}
#endif
