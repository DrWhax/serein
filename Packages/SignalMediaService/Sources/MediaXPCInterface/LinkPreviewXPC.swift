// The XPC boundary to SignalLinkPreviewParser.xpc: link-preview pages (untrusted HTML fetched
// by SignalLinkPreviewFetcher.xpc) are parsed there, in a process of their own under App
// Sandbox plus the tight Seatbelt profile in Sandbox/SignalLinkPreviewParser.sb (no files,
// network, processes, Mach services or preferences). It parses text only: a preview's image is
// decoded by the media decoder service, never here. Only the fetcher sends it HTML, over an
// endpoint the parser hands the app for that (LinkPreviewParserServiceXPCProtocol).

import Foundation

/// The link-preview page parser.
public protocol LinkPreviewParsing: Sendable {
    /// Link-preview HTML (at most 1000 KiB) → its metadata, nil without a title.
    func linkPreviewHTML(_ html: Data, httpCharset: String?) async throws -> LinkPreviewHTML?
}

public enum LinkPreviewParserRequest: Codable, Sendable {
    case html(Data, httpCharset: String?)

    /// The HTML and a charset name.
    public static let maxBytes = LinkPreviewHTML.maxInputBytes + (4 << 10)
}

extension LinkPreviewHTML {
    /// Four fields of at most `maxLength` characters each (a character can take many bytes).
    public static let maxReplyBytes = 4 << 20
}

public final class LinkPreviewParserClient: LinkPreviewParsing {
    public static let serviceName = "org.signalsafe.SignalLinkPreviewParser"
    let channel: XPCChannel

    /// A connection to the parser (the fetcher's, through the endpoint it was handed), only if
    /// the parser is signed as `peer` says.
    public init(timeout: Duration = .seconds(10), peer: String? = nil, makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        channel = XPCChannel(timeout: timeout, peer: peer, makeConnection: makeConnection)
    }

    public func linkPreviewHTML(_ html: Data, httpCharset: String?) async throws -> LinkPreviewHTML? {
        let request = LinkPreviewParserRequest.html(html.prefix(LinkPreviewHTML.maxInputBytes), httpCharset: httpCharset)
        let reply = try await channel.send(try MediaXPCWire.encode(request))
        // Re-checked here: the parser's answer is untrusted too.
        return try MediaXPCWire.decode(LinkPreviewHTML?.self, reply, maxBytes: LinkPreviewHTML.maxReplyBytes)?.validated()
    }
}
