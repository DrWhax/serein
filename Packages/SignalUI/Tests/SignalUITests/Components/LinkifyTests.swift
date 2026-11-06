// The Swift linkify-it against the real one (Fixtures/linkify-oracle.json, generated with
// linkify-it 5.0.2 and Signal's TLD list), plus the sneaky-link rules.

import Foundation
import Testing
@testable import SignalUI
@testable import SignalText

struct LinkifyOracleCase: Decodable {
    struct M: Decodable, Equatable { let schema: String; let index: Int; let lastIndex: Int; let text: String; let url: String }
    let text: String
    let matches: [M]
}

@Suite struct LinkifyTests {
    @Test func matchesLinkifyIt() throws {
        let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = dir.appendingPathComponent("linkify-oracle.json")
        let cases = try JSONDecoder().decode([LinkifyOracleCase].self, from: Data(contentsOf: url))
        for c in cases {
            let ours = LinkifyIt.match(c.text).map {
                LinkifyOracleCase.M(schema: $0.schema, index: $0.index, lastIndex: $0.lastIndex, text: $0.text, url: $0.url)
            }
            #expect(ours == c.matches, "\(c.text)")
        }
    }

    @Test func sneakyLinks() {
        #expect(LinkPreviewRules.isLinkSneaky("https://signal.org/download") == .no)
        #expect(LinkPreviewRules.isLinkSneaky("https://user:pw@signal.org") == .yes)
        #expect(LinkPreviewRules.isLinkSneaky("https://localhost/") == .yes)
        #expect(LinkPreviewRules.isLinkSneaky("https://xn--80ak6aa92e.com/") == .yes)      // Cyrillic + ".com": mixed
        #expect(LinkPreviewRules.isLinkSneaky("https://xn--e1afmkfd.xn--p1ai/") == .no)    // all Cyrillic
        #expect(LinkPreviewRules.isLinkSneaky("https://xn--pple-43d.com/") == .yes)       // mixed ASCII / Cyrillic
        #expect(LinkPreviewRules.isLinkSneaky("https://example.com/aquí") == .maybe)
        #expect(Punycode.toUnicode("xn--e1afmkfd") == "пример")
        #expect(Punycode.toUnicode("xn--p1ai") == "рф")
        #expect(Punycode.toUnicode("xn--pple-43d") == "аpple")
    }
}
