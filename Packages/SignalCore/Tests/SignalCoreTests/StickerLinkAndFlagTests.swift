// Sticker pack links (signalRoutes addStickers) and version-gated feature flags
// (_isFeatureEnabledInner, production).

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct StickerLinkAndFlagTests {
    static let id = "9acc9e8aba563d26a4994e69263e3b25", hex = String(repeating: "ab", count: 32)

    @Test func packLinks() throws {
        let key = Data(repeating: 0xab, count: 32).base64EncodedString()
        let web = try #require(URL(string: "https://signal.art/addstickers/#pack_id=\(Self.id)&pack_key=\(Self.hex)"))
        #expect(Stickers.packLink(web).map { [$0.packId, $0.packKey] } == [Self.id, key])
        let app = try #require(URL(string: "sgnl://addstickers/?pack_id=\(Self.id)&pack_key=\(Self.hex)"))
        #expect(Stickers.packLink(app).map { [$0.packId, $0.packKey] } == [Self.id, key])
        for bad in ["https://signal.art/addstickers/#pack_id=\(Self.id)",                           // no key
                    "https://signal.art/addstickers/#pack_id=xyz&pack_key=\(Self.hex)",             // bad id
                    "https://signal.art/addstickers/#pack_id=\(Self.id)&pack_key=abcd",             // short key
                    "https://signal.art/addstickers/#pack_id=\(Self.id)&pack_key=\(String(repeating: "zz", count: 32))",
                    "https://evil.example/addstickers/#pack_id=\(Self.id)&pack_key=\(Self.hex)",    // another host
                    "http://signal.art/addstickers/#pack_id=\(Self.id)&pack_key=\(Self.hex)"] {     // not https
            #expect(Stickers.packLink(try #require(URL(string: bad))) == nil, "\(bad)")
        }
    }

    @Test func versionGatedFlags() throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        func set(_ config: [String: RemoteConfig.Value]) throws { try database.pool.write { db in try Items.set(db, "remoteConfig", config) } }
        func on(_ version: String) throws -> Bool { try database.pool.read { try RemoteConfig.isFeatureEnabled($0, prodKey: "desktop.x.prod", version: version) } }
        #expect(try on("8.36.0") == false)                                          // not in the config
        try set(["desktop.x.prod": RemoteConfig.Value(name: "", enabled: true, value: "8.30.0")])
        #expect(try on("8.36.0") && on("8.30.0") && !on("8.29.9") && !on("7.99.0"))
        try set(["desktop.x.prod": RemoteConfig.Value(name: "", enabled: true, value: "true")])  // not a version
        #expect(try on("8.36.0") == false)
        try set(["desktop.x.prod": RemoteConfig.Value(name: "", enabled: true, value: "9.0.0"), "desktop.internalUser": RemoteConfig.Value(name: "", enabled: true, value: nil)])
        #expect(try on("8.36.0"))                                                   // internal user
    }
}
