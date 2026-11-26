#if os(Linux)
import CLinuxKeyStore
import Foundation

/// Store the SQLCipher database key in the desktop's default Secret Service
/// collection. A missing session bus, locked collection or corrupt entry is an error.
public struct SecretServiceDatabaseKeyStore: DatabaseKeyStore {
    public let service: String
    public let account: String

    public enum Failure: Error, Equatable {
        case unavailable, corruptKey, busy, invalidIdentifier
    }

    public init(service: String = "org.signalsafe.database", account: String = "sqlcipher-key") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data { try access(removing: false) }
    public func deleteKey() throws { _ = try access(removing: true) }

    private func access(removing: Bool) throws -> Data {
        let serviceBytes = Array(service.utf8), accountBytes = Array(account.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        var buffer = key.mutableSpan
        let status = serein_database_key(serviceBytes.span, accountBytes.span, &buffer, removing ? 1 : 0)
        switch status {
        case SereinKeyOK: return removing ? Data() : Data(key)
        case SereinKeyCorrupt: throw Failure.corruptKey
        case SereinKeyBusy: throw Failure.busy
        case SereinKeyInvalid: throw Failure.invalidIdentifier
        default: throw Failure.unavailable
        }
    }
}

/// The existing app initializer chooses the desktop credential store on Linux.
public typealias KeychainDatabaseKeyStore = SecretServiceDatabaseKeyStore
#endif
