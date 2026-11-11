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

/// The service side of the HTML listener: each request decoded, parsed, and the result encoded
/// back (nil for "no preview").
public final class LinkPreviewXPCHandler: XPCMessageHandler {
    /// A page takes milliseconds; one still being parsed after this ends the process.
    public static let budget: Duration = .seconds(5)
    let gate: RequestGate

    public init(gate: RequestGate = RequestGate()) { self.gate = gate }

    public var maxRequestBytes: Int { LinkPreviewParserRequest.maxBytes }

    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        switch try MediaXPCWire.decode(LinkPreviewParserRequest.self, try request.requirePayload(), maxBytes: LinkPreviewParserRequest.maxBytes) {
        case .html(let html, let charset):
            return XPCMessage(payload: try await gate.run(budget: Self.budget) { try MediaXPCWire.encode(LinkPreviewParser.parse(html, httpCharset: charset)) })
        }
    }
}
