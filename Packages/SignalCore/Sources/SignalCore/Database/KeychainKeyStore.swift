// The SQLCipher key lives in the macOS Keychain (replaces Electron safeStorage +
// `encryptedKey` in Signal Desktop's user config, app/main.main.ts getSQLKey).

import Foundation
import Security

public protocol DatabaseKeyStore: Sendable {
    /// Returns the 32-byte database key, creating and storing one on first use.
    func loadOrCreateKey() throws -> Data
    func deleteKey() throws
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case corruptKey
}

public struct KeychainDatabaseKeyStore: DatabaseKeyStore {
    public let service: String
    public let account: String

    public init(service: String = "org.signalsafe.database", account: String = "sqlcipher-key") {
        self.service = service
        self.account = account
    }

    var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func loadOrCreateKey() throws -> Data {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        // The only `unsafe` in SignalCore: SecItemCopyMatching returns its result through
        // a C out-pointer and the Security framework has no safe Swift wrapper. `item` is a
        // local optional, written once by the call and read as a Swift value afterwards.
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { throw KeychainError.corruptKey }
            return data
        case errSecItemNotFound:
            let key = SignalCrypto.randomBytes(32)
            var add = baseQuery
            add[kSecValueData] = key
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel] = "SignalSafe database key"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
            return key
        default:
            throw KeychainError.status(status)
        }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
