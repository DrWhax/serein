import Foundation
import GRDB
import LibSignalClient
import Testing

@Suite struct DependencySmokeTests {
    @Test func libsignalLinks() throws {
        let k = PrivateKey.generate()
        #expect(k.publicKey.serialize().count == 33)
    }

    @Test func grdbUsesSQLCipher() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-\(UUID()).sqlite").path
        var config = Configuration()
        config.prepareDatabase { db in try db.usePassphrase("x'" + String(repeating: "ab", count: 32) + "'") }
        let q = try DatabaseQueue(path: path, configuration: config)
        let version = try q.read { try String.fetchOne($0, sql: "PRAGMA cipher_version") }
        #expect(version != nil, "SQLCipher not linked")
        let fts = try q.read { try Bool.fetchOne($0, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") }
        #expect(fts == true)
    }
}
