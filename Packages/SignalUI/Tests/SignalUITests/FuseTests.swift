// Fuse (port of Fuse.js 7.1.0) against the JS library: Fixtures/fuse-vectors.json holds
// Fuse.js's ranked results (refIndex, score) for each query over the same documents, with
// upstream's conversation options (threshold 0.2, distance 200, extended search) and with
// the defaults.

import Foundation
import Testing
@testable import SignalUI

@Suite struct FuseTests {
    struct Doc: Decodable { var title: String; var profileName: String?; var username: String?; var e164: String? }
    struct Case: Decodable { var q: String; var plain: Bool?; var r: [[Double]] }
    struct Vectors: Decodable { var docs: [Doc]; var out: [Case] }

    @Test func matchesFuseJS() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/fuse-vectors", withExtension: "json"))
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        let docs = v.docs.map { [$0.title, $0.profileName, $0.username, $0.e164] as [String?] }
        let keys = [Fuse.Key("title"), Fuse.Key("profileName"), Fuse.Key("username"), Fuse.Key("e164", weight: 0.5)]
        let extended = Fuse(documents: docs, keys: keys, options: Fuse.Options(threshold: 0.2, distance: 200, useExtendedSearch: true))
        let plain = Fuse(documents: v.docs.map { [$0.title] }, keys: [Fuse.Key("title")], options: Fuse.Options())
        for c in v.out {
            let got = (c.plain == true ? plain : extended).search(c.q)
            #expect(got.map(\.refIndex) == c.r.map { Int($0[0]) }, "order for \(c.q)")
            for (g, e) in zip(got, c.r) { #expect(abs(g.score - e[1]) < 1e-12, "score for \(c.q) #\(g.refIndex): \(g.score) vs \(e[1])") }
        }
    }

    @Test func searchableTokens() {
        #expect(ConversationSearch.toSearchableTokens("José Ñúñez (LA)") == "Jose Nunez  LA ")
        #expect(ConversationSearch.phoneNumberE164("(555) 123-4567", regionCode: "US") == "+15551234567")
        #expect(ConversationSearch.phoneNumberE164("+44 20 7946 0958", regionCode: "US") == "+442079460958")
        #expect(ConversationSearch.phoneNumberE164("Bob", regionCode: "US") == nil)
    }
}
