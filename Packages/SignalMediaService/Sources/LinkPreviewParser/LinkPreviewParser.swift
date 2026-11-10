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
/// back (nil for "no preview").
public final class LinkPreviewXPCHandler: NSObject, MediaXPCProtocol, Sendable {
    /// A page takes milliseconds; one still being parsed after this ends the process.
    public static let budget: Duration = .seconds(5)
    let gate: RequestGate

    public init(gate: RequestGate = RequestGate()) { self.gate = gate }

    public func handle(_ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        let gate = gate
        Task {
            do {
                switch try MediaXPCWire.decode(LinkPreviewParserRequest.self, request, maxBytes: LinkPreviewParserRequest.maxBytes) {
                case .html(let html, let charset):
                    reply(try await gate.run(budget: Self.budget) { try MediaXPCWire.encode(LinkPreviewParser.parse(html, httpCharset: charset)) }, nil)
                }
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }
}

/// Accepts connections that send HTML (only from a process signed as `peer` says, when given).
public final class LinkPreviewXPCListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let handler = LinkPreviewXPCHandler()
    let peer: String?
    public init(peer: String? = nil) { self.peer = peer }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let peer { connection.setCodeSigningRequirement(peer) }
        connection.exportedInterface = NSXPCInterface(with: MediaXPCProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}

/// The parser service's listener: the app may connect, but only to be handed the endpoint of
/// an anonymous listener that takes HTML from the fetcher alone (the app passes the endpoint
/// to the fetcher with each fetch, and never sends HTML itself).
public final class LinkPreviewParserServiceDelegate: NSObject, NSXPCListenerDelegate, LinkPreviewParserServiceXPCProtocol {
    let appPeer: String?
    let htmlListener: NSXPCListener
    let htmlDelegate: LinkPreviewXPCListenerDelegate

    public init(appPeer: String?, fetcherPeer: String?) {
        self.appPeer = appPeer
        htmlDelegate = LinkPreviewXPCListenerDelegate(peer: fetcherPeer)
        htmlListener = NSXPCListener.anonymous()
        super.init()
        htmlListener.delegate = htmlDelegate
        htmlListener.resume()
    }

    public func parserEndpoint(withReply reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        reply(htmlListener.endpoint)
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let appPeer { connection.setCodeSigningRequirement(appPeer) }
        connection.exportedInterface = NSXPCInterface(with: LinkPreviewParserServiceXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}
