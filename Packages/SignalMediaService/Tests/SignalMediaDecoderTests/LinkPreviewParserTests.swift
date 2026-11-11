import Foundation
import LinkPreviewParser
@testable import MediaXPCInterface
import Testing
import XPC

/// SignalLinkPreviewParser.xpc's path in process: an anonymous listener with the service's
/// handler, and a client connected to it.
@Suite struct LinkPreviewParserTests {
    @Test func parsesThroughXPC() async throws {
        let listener = XPCServer.anonymous(requirement: nil, LinkPreviewXPCHandler())
        defer { listener.cancel() }
        let client = LinkPreviewParserClient(.endpoint(listener.endpoint), timeout: .seconds(10))
        let html = Data("""
            <html><head><meta property="og:title" content="A &amp; B"><meta property="og:description" content="About it">
            <meta property="og:image" content="/i.png"><title>ignored</title></head></html>
            """.utf8)
        let m = try #require(try await client.linkPreviewHTML(html, httpCharset: "utf-8"))
        #expect(m.title == "A & B" && m.description == "About it" && m.imageHref == "/i.png")
        // No title: no preview.
        #expect(try await client.linkPreviewHTML(Data("<html><body>hi</body></html>".utf8), httpCharset: nil) == nil)
        // Not HTML at all.
        #expect(try await client.linkPreviewHTML(Data([0xFF, 0x00, 0x13]), httpCharset: nil) == nil)
    }

    @Test func longFieldsAreCut() async throws {
        let long = String(repeating: "x", count: LinkPreviewHTML.maxLength * 2)
        let html = Data("<meta property=\"og:title\" content=\"\(long)\">".utf8)
        let m = try #require(try await LinkPreviewParser().linkPreviewHTML(html, httpCharset: nil))
        #expect(m.title.count == LinkPreviewHTML.maxLength)
        #expect(try m.validated() == m)
    }

    /// A reply that breaks the limits (a compromised parser) is refused by the client.
    @Test func clientRevalidates() async throws {
        struct Hostile: XPCMessageHandler {
            var maxRequestBytes: Int { 1 << 20 }
            func reply(to request: XPCMessage) async throws -> XPCMessage {
                let bad = LinkPreviewHTML(title: String(repeating: "y", count: LinkPreviewHTML.maxLength + 1), description: nil, imageHref: nil, rawDate: nil)
                return XPCMessage(payload: try MediaXPCWire.encode(Optional(bad)))
            }
        }
        let listener = XPCServer.anonymous(requirement: nil, Hostile())
        defer { listener.cancel() }
        let client = LinkPreviewParserClient(.endpoint(listener.endpoint), timeout: .seconds(10))
        await #expect(throws: MediaProcessingError.self) { try await client.linkPreviewHTML(Data("<title>t</title>".utf8), httpCharset: nil) }
    }

    /// The parser service only hands out the HTML listener's endpoint: HTML sent to it is
    /// refused, while the endpoint parses.
    @Test func theServiceTakesNoHTML() async throws {
        let service = XPCServer.anonymous(requirement: nil, EndpointService(requirement: nil, LinkPreviewXPCHandler()))
        defer { service.cancel() }
        let page = Data("<title>t</title>".utf8)
        await #expect(throws: MediaProcessingError.self) {
            try await LinkPreviewParserClient(.endpoint(service.endpoint), timeout: .seconds(10)).linkPreviewHTML(page, httpCharset: nil)
        }
        let endpoint = try await LinkPreviewFetcherClient(parser: .endpoint(service.endpoint), parserPeer: nil).parserEndpoint()
        #expect(try await LinkPreviewParserClient(.endpoint(endpoint), timeout: .seconds(10)).linkPreviewHTML(page, httpCharset: nil)?.title == "t")
    }

    /// Many requests at once on a new client share one session.
    @Test func concurrentRequestsShareASession() async throws {
        let listener = XPCServer.anonymous(requirement: nil, LinkPreviewXPCHandler())
        defer { listener.cancel() }
        let client = LinkPreviewParserClient(.endpoint(listener.endpoint), timeout: .seconds(10))
        let titles = try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<20 { group.addTask { try await client.linkPreviewHTML(Data("<title>\(i)</title>".utf8), httpCharset: nil)?.title } }
            var out: [String] = []
            for try await t in group { out.append(t ?? "") }
            return out
        }
        #expect(Set(titles) == Set((0..<20).map(String.init)))
    }
}
