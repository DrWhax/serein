import Foundation

public protocol DatabaseKeyStore: Sendable {
    /// Returns the 32-byte database key, creating and storing one on first use.
    func loadOrCreateKey() throws -> Data
    func deleteKey() throws
}
