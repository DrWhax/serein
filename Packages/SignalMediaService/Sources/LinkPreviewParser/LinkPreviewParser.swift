// LinkPreviewParsing over SignalCodecs' HTMLMeta (the grammar for the `<meta>` / `<link>` /
// `<title>` subset upstream's parseMetadata reads): the service side of
// SignalLinkPreviewParser.xpc, and the in-process parser tests use.

import CodecCore
import Foundation
import HTMLMeta
import MediaXPCInterface

public struct LinkPreviewParser: LinkPreviewParsing {
    public init() {}

    public func linkPreviewHTML(_ html: Data, httpCharset: String?) async throws -> LinkPreviewHTML? {
        Self.parse(html, httpCharset: httpCharset)
    }

    static func parse(_ html: Data, httpCharset: String?) -> LinkPreviewHTML? {
        let bytes = Array(html.prefix(min(HTMLPreview.maxBytes, LinkPreviewHTML.maxInputBytes)))
        guard let m = HTMLPreview.parse(ByteSlice(bytes), httpCharset: httpCharset), let title = m.title else { return nil }
        // Bounded here as well as by the client, so an over-long field is cut, not an error.
        func bound(_ s: String?) -> String? { s.map { String($0.prefix(LinkPreviewHTML.maxLength)) } }
        return LinkPreviewHTML(title: String(title.prefix(LinkPreviewHTML.maxLength)), description: bound(m.description),
                               imageHref: bound(m.imageHref), rawDate: bound(m.rawDate))
    }
}

/// The service side of the XPC protocol: each request decoded, parsed, and the result encoded
/// back (an empty array for "no preview").
public final class LinkPreviewXPCHandler: NSObject, MediaXPCProtocol, Sendable {
    public func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            switch try MediaXPCWire.decode(LinkPreviewParserRequest.self, request) {
            case .html(let html, let charset):
                reply(try MediaXPCWire.encode(LinkPreviewParser.parse(html, httpCharset: charset).map { [$0] } ?? []), nil)
            }
        } catch {
            reply(nil, String(describing: error))
        }
    }
}

public final class LinkPreviewXPCListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let handler = LinkPreviewXPCHandler()
    public override init() {}
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MediaXPCProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
