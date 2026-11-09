// Call link URLs: a generated root key makes a signal.link/call URL that parses back to the
// same key; other links are not call links.

import Foundation
import SignalRingRTC
import Testing
@testable import SignalCore

@Suite struct CallLinkURLTests {
    @Test func roundTrip() throws {
        let key = try CallLinkRootKey.generate()
        let url = try CallLinkURL.url(rootKey: key.bytes)
        #expect(url.hasPrefix("https://signal.link/call/#key="))
        let link = try #require(URL(string: url))
        let parsed = try #require(CallLinkURL.rootKey(from: link))
        #expect(parsed.bytes == key.bytes)
        let sgnl = try #require(URL(string: url.replacingOccurrences(of: "https://", with: "sgnl://")))
        #expect(CallLinkURL.rootKey(from: sgnl)?.bytes == key.bytes)
    }

    @Test func notCallLinks() throws {
        for s in ["https://signal.link/call/", "https://signal.link/call/#key=nope", "https://example.com/call/#key=bcdf",
                  "https://signal.group/#abc", "http://signal.link/call/#key=bcdf-bcdf"] {
            let u = try #require(URL(string: s))
            #expect(CallLinkURL.rootKey(from: u) == nil, "\(s)")
        }
    }
}
