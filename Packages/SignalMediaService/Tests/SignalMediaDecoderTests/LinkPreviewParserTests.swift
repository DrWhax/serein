import Foundation
import LinkPreviewParser
import MediaXPCInterface
import Testing

/// SignalLinkPreviewParser.xpc's path in process: an anonymous listener with the service's
/// delegate, and the app's client connected to it.
@Suite struct LinkPreviewParserTests {
    @Test func parsesThroughXPC() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = LinkPreviewXPCListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let client = LinkPreviewParserClient(timeout: .seconds(10)) { NSXPCConnection(listenerEndpoint: endpoint) }
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
        final class Hostile: NSObject, MediaXPCProtocol, NSXPCListenerDelegate, Sendable {
            func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
                let bad = LinkPreviewHTML(title: String(repeating: "y", count: LinkPreviewHTML.maxLength + 1), description: nil, imageHref: nil, rawDate: nil)
                reply(try? MediaXPCWire.encode(Optional(bad)), nil)
            }
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
                c.exportedInterface = NSXPCInterface(with: MediaXPCProtocol.self)
                c.exportedObject = self
                c.resume()
                return true
            }
        }
        let listener = NSXPCListener.anonymous()
        let hostile = Hostile()
        listener.delegate = hostile
        listener.resume()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let client = LinkPreviewParserClient(timeout: .seconds(10)) { NSXPCConnection(listenerEndpoint: endpoint) }
        await #expect(throws: MediaProcessingError.self) { try await client.linkPreviewHTML(Data("<title>t</title>".utf8), httpCharset: nil) }
    }
}
