// Call-link titles sealed with libsignal's AES-256-GCM-SIV (CallLinkTitles) against native
// RingRTC's RustCrypto implementation, in both directions, for V0 and V1 root keys.

import Foundation
import RingRTCNative
@testable import SignalCore
@testable import SignalRingRTC
import Testing

@Suite(.serialized) struct CallLinkTitleTests {
    static let v0 = try! CallLinkRootKey.fromBytes(Data(0..<16))
    static let v1 = try! CallLinkRootKey.fromBytes(Data(0..<16) + [1, 0x12, 0x34, 0x56, 0x78])

    @Test(arguments: [v0, v1]) func roundTripAndLayout(root: CallLinkRootKey) throws {
        let titles = CallLinkTitles()
        #expect(try titles.seal("", rootKey: root).isEmpty)
        for title in ["a", "Practice room", "Afternoon music ☀️", String(repeating: "Ā", count: 40)] {
            let sealed = try titles.seal(title, rootKey: root)
            // nonce || whole 32-byte blocks of nonce and padded plaintext || 16-byte tag
            #expect((sealed.count - 16) % 32 == 0 && sealed.count >= 12 + title.utf8.count + 1 + 16)
            // (A 1-byte title shows up by chance in ~1 of 5 random records; 4+ bytes ~never.)
            if title.utf8.count >= 4 { #expect(sealed.range(of: Data(title.utf8)) == nil) }
            #expect(titles.open(sealed, rootKey: root) == title)
            #expect(try titles.seal(title, rootKey: root) != sealed)   // a fresh nonce each time
        }
        #expect(throws: CallLinkTitles.Failure.tooLong) {
            try titles.seal(String(repeating: "x", count: CallLinkTitles.maxTitleBytes + 1), rootKey: root)
        }
    }

    @Test func tamperedRecordsAndOtherLinksDoNotOpen() throws {
        let titles = CallLinkTitles()
        let sealed = try titles.seal("Practice room", rootKey: Self.v0)
        for bit in 0..<(sealed.count * 8) {
            var bad = sealed
            bad[bit / 8] ^= 1 << UInt8(bit % 8)
            #expect(titles.open(bad, rootKey: Self.v0) == nil)
        }
        #expect(titles.open(sealed.dropLast(), rootKey: Self.v0) == nil)
        #expect(titles.open(sealed, rootKey: try CallLinkRootKey.generate()) == nil)
        // The V1 key's cipher is keyed by a different info string over the same 16-byte root.
        #expect(titles.open(sealed, rootKey: Self.v1) == nil)
    }

    /// The SFU stores what one client sealed; every other client must open it. Native RingRTC
    /// seals with RustCrypto inside ringrtc; CallLinkTitles opens that, and the reverse.
    @MainActor @Test(arguments: [v0, v1]) func interoperatesWithNativeRingRTC(root: CallLinkRootKey) async throws {
        let native = try RingRTC(endpoint: NativeEndpoint.factory)
        defer { native.handleSendHttpRequest = nil }
        let title = "Music rehearsal 🎻"
        var nativeSealed: Data?
        native.handleSendHttpRequest = { id, _, method, _, body in
            #expect(method == .put)
            let json = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            nativeSealed = json?["name"].data
            let reply = #"{"name":"\#(nativeSealed?.base64EncodedString() ?? "")","revoked":false,"restrictions":"none","expiration":99}"#
            native.receivedHttpResponse(requestId: id, status: 200, body: Data(reply.utf8))
        }
        _ = await native.updateCallLinkName(sfuUrl: "https://sfu.example", authCredentialPresentation: Data([9]), linkRootKey: root,
                                            adminPasskey: Data([42]), newName: title)
        let fromNative = try #require(nativeSealed)
        #expect(CallLinkTitles().open(fromNative, rootKey: root) == title)

        let ours = try CallLinkTitles().seal(title, rootKey: root)
        native.handleSendHttpRequest = { id, _, method, _, _ in
            #expect(method == .get)
            let reply = #"{"name":"\#(ours.base64EncodedString())","revoked":false,"restrictions":"none","expiration":99}"#
            native.receivedHttpResponse(requestId: id, status: 200, body: Data(reply.utf8))
        }
        guard case .success(let state) = await native.readCallLink(sfuUrl: "https://sfu.example", authCredentialPresentation: Data([9]),
                                                                   linkRootKey: root) else {
            Issue.record("native RingRTC did not read the link")
            return
        }
        #expect(state.name == title)
    }
}
