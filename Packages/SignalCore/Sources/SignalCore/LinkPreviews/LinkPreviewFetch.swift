// ts/linkPreviews/linkPreviewFetch.preload.ts: fetching a page (manual redirects, header
// checks, at most 1000 KiB of HTML) and its preview image (at most 1 MiB). The HTML is parsed
// only by SignalLinkPreviewParser.xpc (LinkPreviewParsing), the image read only by the sandboxed
// media decoder (MediaProcessing, our Swift decoders).
//
// The app fetches directly (`ContentProxy.direct`), as Desktop upstream does: Signal's content
// proxy (contentproxy.signal.org:443, an HTTP CONNECT proxy) only lets a fixed set of hosts
// through (Giphy and the like) and answers 403 for other sites. `.signal` remains for those
// hosts (the GIF picker); `.custom` is the test harness's stand-in proxy.

import Foundation
import MediaXPCInterface
import SignalText

public struct LinkPreviewHTTPResponse: Sendable {
    public var status: Int
    /// Lower-cased names.
    public var headers: [String: String]
    /// At most `limit + 1` bytes (one more than allowed means "too large").
    public var body: Data
    public var url: URL

    public init(status: Int, headers: [String: String], body: Data, url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }
}

/// One GET, never following redirects.
public protocol LinkPreviewTransport: Sendable {
    func get(_ url: URL, headers: [String: String], limit: Int) async throws -> LinkPreviewHTTPResponse
}

public enum ContentProxy: Sendable, Equatable {
    case signal
    case custom(host: String, port: Int)
    case direct

    var dictionary: [AnyHashable: Any]? {
        switch self {
        case .signal: return ["HTTPSEnable": 1, "HTTPSProxy": "contentproxy.signal.org", "HTTPSPort": 443]
        case .custom(let host, let port): return ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        case .direct: return nil
        }
    }
}

/// The preview session's only delegate: redirects are never followed (fetchWithRedirects checks
/// each hop), and server trust is evaluated here. (A per-task delegate would also receive the
/// trust challenge, so there is none.)
final class LinkPreviewSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let trust: PinnedTrustDelegate
    init(rootsDER: [Data]) { trust = PinnedTrustDelegate(rootsDER: rootsDER) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trust.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await trust.urlSession(session, didReceive: challenge)
    }
}

/// URLSession transport: ephemeral, no cookies or cache, through the content proxy.
public struct URLSessionLinkPreviewTransport: LinkPreviewTransport {
    let session: URLSession

    public init(proxy: ContentProxy = .signal, rootCertificatesDER: [Data] = []) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.connectionProxyDictionary = proxy.dictionary
        session = URLSession(configuration: config, delegate: LinkPreviewSessionDelegate(rootsDER: rootCertificatesDER), delegateQueue: nil)
    }

    public func get(_ url: URL, headers: [String: String], limit: Int) async throws -> LinkPreviewHTTPResponse {
        try await request("GET", url, headers: headers, limit: limit)
    }

    /// One request (GET, HEAD); the body is read up to `limit + 1` bytes.
    public func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> LinkPreviewHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        var body = Data()
        if !(300..<400).contains(http.statusCode) && method != "HEAD" {
            for try await b in bytes {
                body.append(b)
                if body.count > limit { break }
            }
        }
        bytes.task.cancel()
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
        return LinkPreviewHTTPResponse(status: http.statusCode, headers: out, body: body, url: http.url ?? url)
    }
}

public struct LinkPreviewImage: Sendable, Equatable {
    public var data: Data
    public var contentType: String
}

public struct LinkPreviewMetadata: Sendable, Equatable {
    public var title: String
    public var description: String?
    public var date: Int64?
    /// An image URL to fetch, or the image itself (when the link is an image).
    public var imageHref: String?
    public var image: LinkPreviewImage?
}

public enum LinkPreviewFetch {
    static let userAgent = "WhatsApp/2"
    static let maxRedirects = 20
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    public static let maxHTMLBytes = 1000 * 1024
    public static let maxImageBytes = 1024 * 1024
    static let minHTMLLength = 8
    static let minImageLength = 8
    static let validImageTypes: Set<String> = ["image/gif", "image/x-icon", "image/jpeg", "image/png", "image/webp"]
    /// `MAX_DATE`: 3000-01-01 (local time upstream; UTC here).
    static let maxDate: Int64 = 32_503_680_000_000

    /// `fetchWithRedirects`: every hop must itself be previewable; loops and more than 20
    /// requests fail.
    static func fetchWithRedirects(_ transport: any LinkPreviewTransport, _ href: String, headers: [String: String], limit: Int) async throws
        -> LinkPreviewHTTPResponse
    {
        var seen = Set<String>()
        var next = href
        for _ in 0..<maxRedirects {
            guard seen.insert(next).inserted else { throw LinkPreviewError.redirectLoop }
            guard let url = URL(string: next) else { throw LinkPreviewError.invalidURL }
            let response = try await transport.get(url, headers: headers, limit: limit)
            guard redirectStatuses.contains(response.status) else { return response }
            guard let location = response.headers["location"] else { throw LinkPreviewError.noLocation }
            guard let target = LinkPreviewRules.parse(location, relativeTo: next), LinkPreviewRules.shouldPreviewHref(target.absoluteString) else {
                throw LinkPreviewError.invalidURL
            }
            next = target.absoluteString
        }
        throw LinkPreviewError.tooManyRedirects
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
    static func parseDate(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
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
    public static func metadata(_ transport: any LinkPreviewTransport, parser: any LinkPreviewParsing, media: any MediaProcessing, href: String,
                                log: @Sendable (String) -> Void = { _ in }) async -> LinkPreviewMetadata? {
        let response: LinkPreviewHTTPResponse
        do {
            response = try await fetchWithRedirects(transport, href, headers: ["Accept": "text/html,application/xhtml+xml", "User-Agent": userAgent],
                                                    limit: max(maxHTMLBytes, maxImageBytes))
        } catch {
            log("fetch failed: \(error)")
            return nil
        }
        guard (200..<300).contains(response.status), !response.body.isEmpty,
              isInline(response.headers["content-disposition"]),
              contentLength(response.headers["content-length"]) >= minHTMLLength else {
            log("unusable response: status \(response.status), \(response.body.count) bytes")
            return nil
        }
        let (type, charset) = contentType(response.headers["content-type"])
        guard type == "text/html" else {
            guard let type, validImageTypes.contains(type), let image = await processImage(response, media: media) else {
                log("not a page or usable image: \(type ?? "no type")")
                return nil
            }
            return LinkPreviewMetadata(title: response.url.lastPathComponent == "/" ? "" : response.url.lastPathComponent, description: nil, date: nil,
                                       imageHref: nil, image: image)
        }
        let html: LinkPreviewHTML?
        do {
            html = try await parser.linkPreviewHTML(response.body.prefix(maxHTMLBytes), httpCharset: charset)?.validated()
        } catch {
            log("parser failed: \(error)")
            return nil
        }
        guard let html else {
            log("page has no title (\(response.body.count) bytes)")
            return nil
        }
        let imageHref = html.imageHref.flatMap { LinkPreviewRules.parse($0, relativeTo: response.url.absoluteString)?.absoluteString }
        return LinkPreviewMetadata(title: html.title, description: html.description, date: html.rawDate.flatMap(parseDate), imageHref: imageHref, image: nil)
    }

    /// `fetchLinkPreviewImage`
    public static func image(_ transport: any LinkPreviewTransport, media: any MediaProcessing, href: String) async -> LinkPreviewImage? {
        guard let response = try? await fetchWithRedirects(transport, href, headers: ["User-Agent": userAgent], limit: maxImageBytes),
              (200..<300).contains(response.status) else { return nil }
        return await processImage(response, media: media)
    }

    /// `processImageResponse`: an allowed image type, at most 1 MiB; GIFs stay as they are,
    /// others are re-encoded by the media service (`scaleImageToLevel`).
    static func processImage(_ response: LinkPreviewHTTPResponse, media: any MediaProcessing) async -> LinkPreviewImage? {
        guard contentLength(response.headers["content-length"]) >= minImageLength,
              let type = contentType(response.headers["content-type"]).type, validImageTypes.contains(type),
              !response.body.isEmpty, response.body.count <= maxImageBytes else { return nil }
        if type == "image/gif" {
            guard (try? await media.imageInfo(response.body).validated()) != nil else { return nil }
            return LinkPreviewImage(data: response.body, contentType: type)
        }
        guard let scaled = try? await media.scaleForSending(response.body, contentType: type, level: .one)
            .validated(maxDimension: MediaQualityLevel.one.data.maxDimensions) else { return nil }
        return LinkPreviewImage(data: scaled.data, contentType: scaled.contentType)
    }
}

public enum LinkPreviewError: Error, Equatable {
    case redirectLoop, noLocation, invalidURL, tooManyRedirects
}
