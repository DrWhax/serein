// The web-facing services: what the app may ask them and what comes back. The app never
// fetches or parses anything from the web itself:
//   * SignalLinkPreviewFetcher.xpc fetches a link's page (or image) from the site, hands the
//     HTML to SignalLinkPreviewParser.xpc over a session the app brokers (an endpoint the
//     parser only lets the fetcher use), and returns the parsed fields plus image bytes it
//     never reads; the app sends those bytes to SignalMediaDecoder.xpc.
//   * SignalGifSearch.xpc talks to Giphy through Signal's content proxy, decodes its JSON, and
//     returns search results and GIF files (bytes, decoded later by the media decoder).
// Every result is untrusted and re-validated here before the app uses it.

import Foundation
import XPC

// MARK: Link previews

/// A preview image as fetched: its bytes, unread by the fetcher (the media decoder checks them).
public struct FetchedImage: Codable, Equatable, Sendable {
    /// `MAX_IMAGE_CONTENT_LENGTH` (1 MiB).
    public static let maxBytes = 1024 * 1024
    /// `VALID_IMAGE_MIME_TYPES`
    public static let validTypes: Set<String> = ["image/gif", "image/x-icon", "image/jpeg", "image/png", "image/webp"]
    public var data: Data
    public var contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    public func validated() throws -> FetchedImage {
        guard !data.isEmpty, data.count <= Self.maxBytes, Self.validTypes.contains(contentType) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// `fetchLinkPreviewMetadata`'s result: the page's fields (parsed by the parser service, bounded),
/// its date already parsed, the image URL resolved against the final URL; or, for a link that
/// is itself an image, that image.
public struct FetchedLinkPreview: Codable, Equatable, Sendable {
    public var title: String
    public var description: String?
    /// Milliseconds since 1970, within (0, 3000-01-01).
    public var date: Int64?
    public var imageHref: String?
    public var image: FetchedImage?

    public init(title: String, description: String?, date: Int64?, imageHref: String?, image: FetchedImage?) {
        self.title = title
        self.description = description
        self.date = date
        self.imageHref = imageHref
        self.image = image
    }

    public func validated() throws -> FetchedLinkPreview {
        let max = LinkPreviewHTML.maxLength
        guard title.count <= max, (description?.count ?? 0) <= max, (imageHref?.count ?? 0) <= max,
              date.map({ $0 > 0 && $0 < 32_503_680_000_000 }) ?? true,
              imageHref.map({ $0.hasPrefix("https://") && !$0.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F } }) ?? true
        else { throw MediaProcessingError.invalidResult }
        var out = self
        out.image = try image?.validated()
        return out
    }
}

public protocol LinkPreviewFetching: Sendable {
    /// The preview for a link (already checked with LinkPreviewRules); nil when there is none.
    func page(_ href: String) async throws -> FetchedLinkPreview?
    /// `fetchLinkPreviewImage`; nil when there is no usable image.
    func image(_ href: String) async throws -> FetchedImage?
}

extension FetchedImage {
    public static let maxReplyBytes = maxBytes + (4 << 10)
}

extension FetchedLinkPreview {
    /// Its strings (as LinkPreviewHTML) and, for a link to an image, the image.
    public static let maxReplyBytes = FetchedImage.maxReplyBytes + LinkPreviewHTML.maxReplyBytes
}

public enum LinkPreviewFetchRequest: Codable, Sendable {
    case page(String)
    case image(String)

    public static let maxBytes = 64 << 10
}

public final class LinkPreviewFetcherClient: LinkPreviewFetching {
    public static let serviceName = "org.signalsafe.SignalLinkPreviewFetcher"
    let fetcher: XPCChannel
    let parser: XPCChannel

    /// The bundled fetcher and parser, or (tests) listeners.
    public init(timeout: Duration = .seconds(60),
                fetcher: XPCTarget = .service(LinkPreviewFetcherClient.serviceName), fetcherPeer: XPCPeerRequirement? = XPCPeer.requirement(.fetcher),
                parser: XPCTarget = .service(LinkPreviewParserClient.serviceName), parserPeer: XPCPeerRequirement? = XPCPeer.requirement(.parser)) {
        self.fetcher = XPCChannel(fetcher, peer: fetcherPeer, timeout: timeout)
        self.parser = XPCChannel(parser, peer: parserPeer, timeout: .seconds(10))
    }

    /// The parser's HTML endpoint: the parser service's whole answer to an empty message (it
    /// takes HTML from the fetcher alone, so the app never sends it any).
    func parserEndpoint() async throws -> XPCEndpoint {
        try await parser.request(XPCMessage(), maxReply: 0) { reply in
            guard let endpoint = reply.endpoint else { throw MediaProcessingError.undecodable(reply.error ?? "no parser endpoint") }
            return endpoint
        }
    }

    /// One fetch, with the endpoint of the parser the fetcher may use.
    func call(_ request: LinkPreviewFetchRequest, maxReply: Int) async throws -> Data {
        let endpoint = try await parserEndpoint()
        return try await fetcher.request(XPCMessage(payload: try MediaXPCWire.encode(request), endpoint: endpoint), maxReply: maxReply) { try $0.result() }
    }

    public func page(_ href: String) async throws -> FetchedLinkPreview? {
        try MediaXPCWire.decode(FetchedLinkPreview?.self, try await call(.page(href), maxReply: FetchedLinkPreview.maxReplyBytes),
                                maxBytes: FetchedLinkPreview.maxReplyBytes)?.validated()
    }

    public func image(_ href: String) async throws -> FetchedImage? {
        try MediaXPCWire.decode(FetchedImage?.self, try await call(.image(href), maxReply: FetchedImage.maxReplyBytes), maxBytes: FetchedImage.maxReplyBytes)?.validated()
    }
}

// MARK: GIF search (Giphy)

public struct GifMedia: Codable, Sendable, Equatable {
    public var url: URL
    public var width: Int
    public var height: Int

    public init(url: URL, width: Int, height: Int) {
        self.url = url
        self.width = width
        self.height = height
    }
}

/// `GifType`
public struct GifResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    /// fixed_width (200 px) MP4, for the picker.
    public var previewMedia: GifMedia
    /// original MP4, what is sent.
    public var attachmentMedia: GifMedia

    public init(id: String, title: String, description: String, previewMedia: GifMedia, attachmentMedia: GifMedia) {
        self.id = id
        self.title = title
        self.description = description
        self.previewMedia = previewMedia
        self.attachmentMedia = attachmentMedia
    }
}

/// `PaginatedGifResults`
public struct PaginatedGifResults: Codable, Sendable, Equatable {
    /// Offset of the next page; nil at the end.
    public var next: Int?
    public var gifs: [GifResult]

    public init(next: Int?, gifs: [GifResult]) {
        self.next = next
        self.gifs = gifs
    }

    public static let maxPage = 200
    public static let cdnHosts: Set<String> = ["media0.giphy.com", "media1.giphy.com", "media2.giphy.com", "media3.giphy.com", "media4.giphy.com"]

    /// `isGiphyCdnUrl`: https on one of the media hosts, default port, no credentials.
    public static func isGiphyCdnURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", let host = c.host, cdnHosts.contains(host),
              c.port == nil, c.user == nil, c.password == nil else { return false }
        return true
    }

    public func validated() throws -> PaginatedGifResults {
        func ok(_ m: GifMedia) -> Bool { Self.isGiphyCdnURL(m.url) && (1...8192).contains(m.width) && (1...8192).contains(m.height) }
        guard gifs.count <= Self.maxPage, (next ?? 0) >= 0,
              gifs.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 256 && $0.title.count <= 1024 && $0.description.count <= 4096
                                  && ok($0.previewMedia) && ok($0.attachmentMedia) })
        else { throw MediaProcessingError.invalidResult }
        return self
    }
}

public protocol GifSearching: Sendable {
    func search(_ query: String, limit: Int, offset: Int?) async throws -> PaginatedGifResults
    func trending(limit: Int, offset: Int?) async throws -> PaginatedGifResults
    /// `fetchGiphyFile`: an MP4 from Giphy's CDN (bytes for the media decoder).
    func file(_ url: URL) async throws -> Data
}

public enum GifSearchRequest: Codable, Sendable {
    case search(String, limit: Int, offset: Int?)
    case trending(limit: Int, offset: Int?)
    case file(URL)

    public static let maxBytes = 64 << 10
}

extension PaginatedGifResults {
    /// A page of at most `maxPage` results, each a few URLs and strings.
    public static let maxReplyBytes = 4 << 20
}

public final class GifSearchClient: GifSearching {
    public static let serviceName = "org.signalsafe.SignalGifSearch"
    /// Larger files are refused (Giphy originals are a few MB).
    public static let maxFileBytes = 32 << 20
    let channel: XPCChannel

    public init(timeout: Duration = .seconds(60), target: XPCTarget = .service(GifSearchClient.serviceName),
                peer: XPCPeerRequirement? = XPCPeer.requirement(.gifs)) {
        channel = XPCChannel(target, peer: peer, timeout: timeout)
    }

    public func search(_ query: String, limit: Int, offset: Int?) async throws -> PaginatedGifResults {
        try MediaXPCWire.decode(PaginatedGifResults.self, try await channel.send(try MediaXPCWire.encode(GifSearchRequest.search(query, limit: limit, offset: offset)),
                                                                                  maxReply: PaginatedGifResults.maxReplyBytes),
                                maxBytes: PaginatedGifResults.maxReplyBytes)
            .validated()
    }

    public func trending(limit: Int, offset: Int?) async throws -> PaginatedGifResults {
        try MediaXPCWire.decode(PaginatedGifResults.self, try await channel.send(try MediaXPCWire.encode(GifSearchRequest.trending(limit: limit, offset: offset)),
                                                                                  maxReply: PaginatedGifResults.maxReplyBytes),
                                maxBytes: PaginatedGifResults.maxReplyBytes)
            .validated()
    }

    public func file(_ url: URL) async throws -> Data {
        guard PaginatedGifResults.isGiphyCdnURL(url) else { throw MediaProcessingError.unsupportedFormat }
        let data = try MediaXPCWire.decode(Data.self, try await channel.send(try MediaXPCWire.encode(GifSearchRequest.file(url)), maxReply: Self.maxFileBytes + 64),
                                           maxBytes: Self.maxFileBytes + 64)
        guard !data.isEmpty, data.count <= Self.maxFileBytes else { throw MediaProcessingError.invalidResult }
        return data
    }
}
