import Foundation
import Security
import SnowlitCore
import SnowlitStorage
import Testing

struct CredentialStoreTests {
    @Test func keychainReopensUpdatesAndRemovesOnlyTheSelectedInstallation() async throws {
        let prefix = "io.github.bemarkt.snowlit.tests.credentials." + UUID().uuidString.lowercased()
        let store = try KeychainCredentialStore(servicePrefix: prefix)
        let first = SourceInstallationID(), second = SourceInstallationID()
        let sharedID = UUID()
        let a = StoredCredentialID(installationID: first, id: sharedID)
        let b = StoredCredentialID(installationID: second, id: sharedID)
        do {
            #expect(try await store.read(a) == nil)
            try await store.write(.init(utf8: "synthetic-first"), for: a)
            try await store.write(.init(utf8: "synthetic-second"), for: b)
            let reopened = try KeychainCredentialStore(servicePrefix: prefix)
            #expect(try await reopened.read(a)?.bytes == Data("synthetic-first".utf8))
            try await reopened.write(.init(utf8: "synthetic-rotated"), for: a)
            #expect(try await store.read(a)?.bytes == Data("synthetic-rotated".utf8))
            #expect(try await store.read(b)?.bytes == Data("synthetic-second".utf8))

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: prefix + "." + first.rawValue.uuidString.lowercased(),
                kSecAttrAccount as String: sharedID.uuidString.lowercased(),
                kSecAttrSynchronizable as String: false,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            #expect(status == errSecSuccess)
            let attributes = try #require(result as? [String: Any])
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            #expect((attributes[kSecAttrSynchronizable as String] as? Bool) != true)

            try await store.removeAll(for: first)
            #expect(try await reopened.read(a) == nil)
            #expect(try await reopened.read(b)?.bytes == Data("synthetic-second".utf8))
            try await reopened.remove(b)
            try await reopened.remove(b)
            #expect(try await store.read(b) == nil)
        } catch {
            try await store.removeAll(for: first)
            try await store.removeAll(for: second)
            throw error
        }
        try await store.removeAll(for: first)
        try await store.removeAll(for: second)
    }
}
