// ts/linkPreviews/linkPreviewFetch.preload.ts, run inside SignalLinkPreviewFetcher.xpc:
// fetching a page (manual redirects, every hop previewable, header checks, at most 1000 KiB
// of HTML) and its preview image (at most 1 MiB). The HTML goes to the parser service; the
// image's bytes go back to the app unread, for the media decoder. Pages are fetched straight
// from the site (`ContentProxy.direct`), as upstream Desktop does: Signal's content proxy
// answers 403 for ordinary sites.

import Foundation
import MediaXPCInterface
import SignalText
import WebFetch

public struct LinkPreviewPageFetcher: LinkPreviewFetching {
    static let userAgent = "WhatsApp/2"
    static let maxRedirects = 20
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    public static let maxHTMLBytes = 1000 * 1024
    static let minHTMLLength = 8
    static let minImageLength = 8
    /// `MAX_DATE`: 3000-01-01 (local time upstream; UTC here).
    static let maxDate: Int64 = 32_503_680_000_000

    let transport: any WebTransport
    let parser: any LinkPreviewParsing
    let log: @Sendable (String) -> Void

    public init(transport: any WebTransport, parser: any LinkPreviewParsing, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.parser = parser
        self.log = log
    }

    /// `fetchWithRedirects`: every hop must itself be previewable; loops and more than 20
    /// requests fail.
    func fetchWithRedirects(_ href: String, headers: [String: String], limit: Int) async throws -> WebResponse {
        var seen = Set<String>()
        var next = href
        for _ in 0..<Self.maxRedirects {
            guard seen.insert(next).inserted else { throw LinkPreviewFetchError.redirectLoop }
            guard LinkPreviewRules.shouldPreviewHref(next), let url = URL(string: next) else { throw LinkPreviewFetchError.invalidURL }
            let response = try await transport.get(url, headers: headers, limit: limit)
            guard Self.redirectStatuses.contains(response.status) else { return response }
            guard let location = response.headers["location"] else { throw LinkPreviewFetchError.noLocation }
            guard let target = LinkPreviewRules.parse(location, relativeTo: next), LinkPreviewRules.shouldPreviewHref(target.absoluteString) else {
                throw LinkPreviewFetchError.invalidURL
            }
            next = target.absoluteString
        }
        throw LinkPreviewFetchError.tooManyRedirects
    }

    /// `parseContentType`
    static func contentType(_ header: String?) -> (type: String?, charset: String?) {
        guard let header, header.count <= 100 else { return (nil, nil) }
        let parts = header.lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let type = parts.first else { return (nil, nil) }
        var charset: String? = nil
        for p in parts.dropFirst() where p.hasPrefix("charset=") {
            let v = p.dropFirst("charset=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !v.isEmpty { charset = v; break }
        }
        return (type, charset)
    }

    /// `isInlineContentDisposition`
    static func isInline(_ header: String?) -> Bool { header.map { $0.split(separator: ";", maxSplits: 1).first.map(String.init) == "inline" } ?? true }

    /// `parseContentLength`: anything but 1–10 digits is "unknown" (∞).
    static func contentLength(_ header: String?) -> Int {
        guard let h = header, (1...10).contains(h.count), h.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(h) else { return .max }
        return n
    }

    /// `Date.parse` for the formats pages use (ISO 8601 with or without fractional seconds,
    /// date-only, RFC 2822); nil outside (0, 3000-01-01).
    public static func parseDate(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 64 else { return nil }
        var date: Date? = nil
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: t) { date = d; break }
        }
        if date == nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z"] {
                f.dateFormat = format
                if let d = f.date(from: t) { date = d; break }
            }
        }
        guard let date else { return nil }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return ms > 0 && ms < maxDate ? ms : nil
    }

    /// `fetchLinkPreviewMetadata`: nil for anything that is not a usable page (or image).
    public func page(_ href: String) async throws -> FetchedLinkPreview? {
        let response: WebResponse
        do {
            response = try await fetchWithRedirects(href, headers: ["Accept": "text/html,application/xhtml+xml", "User-Agent": Self.userAgent],
                                                    limit: max(Self.maxHTMLBytes, FetchedImage.maxBytes))
        } catch {
            log("fetch failed: \(error)")
            return nil
        }
        guard (200..<300).contains(response.status), !response.body.isEmpty, Self.isInline(response.headers["content-disposition"]),
              Self.contentLength(response.headers["content-length"]) >= Self.minHTMLLength else {
            log("unusable response: status \(response.status), \(response.body.count) bytes")
            return nil
        }
        let (type, charset) = Self.contentType(response.headers["content-type"])
        guard type == "text/html" else {
            guard let image = imageResponse(response) else {
                log("not a page or usable image: \(type ?? "no type")")
                return nil
            }
            let name = response.url.lastPathComponent
            return FetchedLinkPreview(title: name == "/" ? "" : String(name.prefix(LinkPreviewHTML.maxLength)), description: nil, date: nil,
                                      imageHref: nil, image: image)
        }
        let html: LinkPreviewHTML?
        do {
            html = try await parser.linkPreviewHTML(response.body.prefix(Self.maxHTMLBytes), httpCharset: charset)?.validated()
        } catch {
            log("parser failed: \(error)")
            return nil
        }
        guard let html else {
            log("page has no title (\(response.body.count) bytes)")
            return nil
        }
        let imageHref = html.imageHref.flatMap { LinkPreviewRules.parse($0, relativeTo: response.url.absoluteString)?.absoluteString }
            .flatMap { $0.count <= LinkPreviewHTML.maxLength && LinkPreviewRules.shouldPreviewHref($0) ? $0 : nil }
        return FetchedLinkPreview(title: html.title, description: html.description, date: html.rawDate.flatMap(Self.parseDate),
                                  imageHref: imageHref, image: nil)
    }

    /// `fetchLinkPreviewImage`
    public func image(_ href: String) async throws -> FetchedImage? {
        guard let response = try? await fetchWithRedirects(href, headers: ["User-Agent": Self.userAgent], limit: FetchedImage.maxBytes),
              (200..<300).contains(response.status) else { return nil }
        return imageResponse(response)
    }

    /// The header checks of `processImageResponse` (an allowed type, at most 1 MiB); the
    /// bytes are not looked at here.
    func imageResponse(_ response: WebResponse) -> FetchedImage? {
        guard Self.contentLength(response.headers["content-length"]) >= Self.minImageLength,
              let type = Self.contentType(response.headers["content-type"]).type, FetchedImage.validTypes.contains(type),
              !response.body.isEmpty, response.body.count <= FetchedImage.maxBytes else { return nil }
        return FetchedImage(data: response.body, contentType: type)
    }
}

public enum LinkPreviewFetchError: Error, Equatable {
    case redirectLoop, noLocation, invalidURL, tooManyRedirects
}

/// The service side of SignalLinkPreviewFetcher.xpc: each fetch with the parser endpoint the
/// app passed along (the parser must be signed as `parserPeer` says).
public final class LinkPreviewFetcherXPCHandler: NSObject, LinkPreviewFetcherXPCProtocol, Sendable {
    let transport: any WebTransport
    let parserPeer: String?
    let gate: RequestGate
    /// The client's timeout: a fetch still running after it, plus grace, ends the process.
    public static let budget: Duration = .seconds(60)

    public init(transport: any WebTransport, parserPeer: String?, gate: RequestGate = RequestGate(maxRunning: 8, maxWaiting: 32)) {
        self.transport = transport
        self.parserPeer = parserPeer
        self.gate = gate
    }

    public func fetch(_ request: Data, parser endpoint: NSXPCListenerEndpoint, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        let decoded: LinkPreviewFetchRequest
        do { decoded = try MediaXPCWire.decode(LinkPreviewFetchRequest.self, request, maxBytes: LinkPreviewFetchRequest.maxBytes) } catch { return reply(nil, "bad request") }
        let box = EndpointBox(endpoint: endpoint)
        let parser = LinkPreviewParserClient(peer: parserPeer) { NSXPCConnection(listenerEndpoint: box.endpoint) }
        let fetcher = LinkPreviewPageFetcher(transport: transport, parser: parser)
        let gate = gate
        Task {
            do {
                reply(try await gate.run(budget: Self.budget) {
                    switch decoded {
                    case .page(let href): return try MediaXPCWire.encode(try await fetcher.page(href))
                    case .image(let href): return try MediaXPCWire.encode(try await fetcher.image(href))
                    }
                }, nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }
}

struct EndpointBox: @unchecked Sendable { let endpoint: NSXPCListenerEndpoint }

public final class LinkPreviewFetcherListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let handler: LinkPreviewFetcherXPCHandler
    let appPeer: String?

    public init(handler: LinkPreviewFetcherXPCHandler, appPeer: String?) {
        self.handler = handler
        self.appPeer = appPeer
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let appPeer { connection.setCodeSigningRequirement(appPeer) }
        connection.exportedInterface = NSXPCInterface(with: LinkPreviewFetcherXPCProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}
