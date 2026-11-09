// The XPC boundary to SignalLinkPreviewParser.xpc: link-preview pages (untrusted HTML fetched
// from any site) are parsed there, in a process of their own under App Sandbox plus the tight
// Seatbelt profile in Sandbox/SignalLinkPreviewParser.sb (no files, network, processes, Mach
// services or preferences). It parses text only: a preview's image is decoded by the media
// decoder service, never here.

import Foundation

/// The link-preview page parser.
public protocol LinkPreviewParsing: Sendable {
    /// Link-preview HTML (at most 1000 KiB) → its metadata, nil without a title.
    func linkPreviewHTML(_ html: Data, httpCharset: String?) async throws -> LinkPreviewHTML?
}

public enum LinkPreviewParserRequest: Codable, Sendable {
    case html(Data, httpCharset: String?)
}

public final class LinkPreviewParserClient: LinkPreviewParsing {
    public static let serviceName = "org.signalsafe.SignalLinkPreviewParser"
    let channel: XPCChannel

    /// The bundled service, or (tests) any connection to a listener.
    public init(timeout: Duration = .seconds(10),
                makeConnection: @escaping @Sendable () -> NSXPCConnection = { NSXPCConnection(serviceName: LinkPreviewParserClient.serviceName) }) {
        channel = XPCChannel(timeout: timeout, makeConnection: makeConnection)
    }

    public func linkPreviewHTML(_ html: Data, httpCharset: String?) async throws -> LinkPreviewHTML? {
        let request = LinkPreviewParserRequest.html(html.prefix(LinkPreviewHTML.maxInputBytes), httpCharset: httpCharset)
        let reply = try await channel.send(try MediaXPCWire.encode(request))
        // Re-checked here: the parser's answer is untrusted too.
        return try MediaXPCWire.decode([LinkPreviewHTML].self, reply).first?.validated()
    }
}
