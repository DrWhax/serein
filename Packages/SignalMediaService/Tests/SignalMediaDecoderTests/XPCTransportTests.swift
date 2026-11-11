// The XPC transport itself (MediaXPCInterface/XPCTransport.swift): what a received dictionary
// may hold, the limits applied before anything is copied out of it, and peers refused by their
// requirement.

import Foundation
import LinkPreviewParser
@testable import MediaXPCInterface
@testable import SignalMediaDecoder
import Testing
import XPC

@Suite struct XPCTransportTests {
    @Test func messagesRoundTrip() throws {
        let listener = XPCServer.anonymous(requirement: nil, LinkPreviewXPCHandler())
        defer { listener.cancel() }
        let m = try XPCMessage(XPCMessage(payload: Data([1, 2, 3]), endpoint: listener.endpoint, error: "why").dictionary, maxPayload: 3)
        #expect(m.payload == Data([1, 2, 3]) && m.endpoint == listener.endpoint && m.error == "why")
        #expect(try XPCMessage(XPCMessage(payload: Data(), error: "").dictionary, maxPayload: 0).payload == Data())
        #expect(try XPCMessage(XPCMessage(error: "").dictionary, maxPayload: 0).error == "")
    }

    /// A payload over the receiver's limit is refused, not cut, by its length before it is
    /// copied; so is one that is not base64. An error over the limit is not read.
    @Test func limitsComeBeforeCopying() throws {
        for size in [0, 1, 2, 3, 99, 100, 101] {
            let d = XPCMessage(payload: Data(count: size)).dictionary
            #expect(throws: MediaProcessingError.invalidResult) { try XPCMessage(d, maxPayload: size - 1) }
            #expect(try XPCMessage(d, maxPayload: size).payload?.count == size)
        }
        var bad = XPCDictionary()
        bad[XPCMessage.payloadKey] = "not base64!"
        #expect(throws: MediaProcessingError.invalidResult) { try XPCMessage(bad, maxPayload: 1 << 20) }
        var long = XPCDictionary()
        long[XPCMessage.errorKey] = String(repeating: "A", count: XPCMessage.maxErrorBytes + 1)
        #expect(try XPCMessage(long, maxPayload: 0).error == XPCMessage.unreadError)
        long[XPCMessage.errorKey] = String(repeating: "A", count: XPCMessage.maxErrorBytes)
        #expect(try XPCMessage(long, maxPayload: 0).error == String(repeating: "A", count: XPCMessage.maxErrorBytes))
        // The sender cuts, at a character.
        #expect(try XPCMessage(XPCMessage(error: String(repeating: "B", count: 4096)).dictionary, maxPayload: 0).error?.utf8.count == XPCMessage.maxErrorBytes)
        #expect(try XPCMessage(XPCMessage(error: String(repeating: "é", count: 300)).dictionary, maxPayload: 0).error == String(repeating: "é", count: 256))
        #expect(XPCMessage.base64Length(Int.max) == Int.max && XPCMessage.base64Length(4) == 8)
    }

    /// Entries of another XPC type are not read as the expected one (XPCDictionary would wrap
    /// a string as an XPCEndpoint).
    @Test func wrongTypesAreAbsent() throws {
        var d = XPCDictionary()
        d[XPCMessage.payloadKey] = true
        d[XPCMessage.endpointKey] = "not an endpoint"
        d[XPCMessage.errorKey] = 42
        #expect(d[XPCMessage.endpointKey, as: XPCEndpoint.self] != nil)   // the overlay's own read
        let m = try XPCMessage(d, maxPayload: 1 << 20)
        #expect(m.payload == nil)
        #expect(m.endpoint == nil)
        #expect(m.error == nil)
        #expect(throws: MediaProcessingError.undecodable("no reply")) { try m.result() }
    }

    /// A request larger than the service reads is refused unread, and the service goes on.
    @Test func oversizedRequestsAreRefused() async throws {
        let listener = XPCServer.anonymous(requirement: nil, LinkPreviewXPCHandler())
        defer { listener.cancel() }
        let channel = XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(10))
        await #expect(throws: MediaProcessingError.self) {
            try await channel.send(Data(count: LinkPreviewParserRequest.maxBytes + 1), maxReply: 1 << 20)
        }
        let ok = try MediaXPCWire.encode(LinkPreviewParserRequest.html(Data("<title>t</title>".utf8), httpCharset: nil))
        let reply = try await channel.send(ok, maxReply: LinkPreviewHTML.maxReplyBytes)
        #expect(try MediaXPCWire.decode(LinkPreviewHTML?.self, reply, maxBytes: LinkPreviewHTML.maxReplyBytes)?.title == "t")
    }

    /// A service whose sessions require a peer nobody is: the client's session ends unserved.
    @Test func theServiceRefusesPeersThatDoNotMeetItsRequirement() async throws {
        let listener = XPCServer.anonymous(requirement: XPCPeer.requirement(identifier: "org.signalsafe.nobody", sameTeam: false), MediaXPCHandler())
        defer { listener.cancel() }
        let client = MediaXPCClient(timeout: .seconds(10), decoder: .endpoint(listener.endpoint), peer: nil)
        await #expect(throws: XPCServiceError.self) { try await client.imageInfo(Data([1])) }
    }
}
