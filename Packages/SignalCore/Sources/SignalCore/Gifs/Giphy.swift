// ts/state/smart/fun/giphy.preload.ts, ts/util/giphy.std.ts and
// ts/components/fun/data/segments.std.ts: GIF search and trending from api.giphy.com, and
// the MP4 renditions from Giphy's CDN, all through the content proxy.
//
// The JSON is decoded against a strict schema (every field upstream's zod schema requires;
// widths/heights as integers or integer strings; media URLs only on media0–4.giphy.com) and
// a "synthetic" response (status 200 with an empty response_id) is an API failure. Files are
// fetched in fixed-size Range segments (1 MiB … 1 KiB buckets), as upstream does so that
// request sizes say little about which GIF was picked; every segment's Content-Length,
// Content-Range and size are checked. Upstream's last-segment adjustment misses the case
// where the last segment would end exactly one byte past the file (`>` for `>=`); here it
// is `>=`. The bytes go to the media service (MP4 demux, H.264) like any received video.

import Foundation

/// One request through the content proxy, never following redirects.
public protocol ProxyHTTPTransport: Sendable {
    func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> LinkPreviewHTTPResponse
}

extension URLSessionLinkPreviewTransport: ProxyHTTPTransport {}

public struct GifMedia: Sendable, Equatable {
    public var url: URL
    public var width: Int
    public var height: Int
}

/// `GifType`
public struct GifResult: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    /// fixed_width (200 px) MP4, for the picker.
    public var previewMedia: GifMedia
    /// original MP4, what is sent.
    public var attachmentMedia: GifMedia
}

/// `PaginatedGifResults`
public struct PaginatedGifResults: Sendable, Equatable {
    /// Offset of the next page; nil at the end.
    public var next: Int?
    public var gifs: [GifResult]
}

public enum GiphyError: Error, Equatable {
    case syntheticResponse
    case invalidResponse(String)
    case blockedURL
    case status(Int)
    case tooLarge(Int)
}

public struct GiphyClient: Sendable {
    public static let baseURL = URL(string: "https://api.giphy.com")!
    public static let apiKey = "ApVVlSyeBfNKK6UWtnBRq9CvAkWsxayB"
    public static let contentRating = "pg-13"
    public static let contentBundle = "messaging_non_clips"
    public static let fields = ["id", "title", "alt_text", "images.original.width", "images.original.height", "images.original.mp4",
                                "images.fixed_width.width", "images.fixed_width.height", "images.fixed_width.mp4"].joined(separator: ",")
    /// GIPHY_SEARCH_QUERY_MAX_CODE_POINTS, enforced as UTF-8 bytes (whole code points).
    public static let maxQueryBytes = 50
    public static let maxResponseBytes = 4 << 20
    /// Larger files are refused (Giphy originals are a few MB).
    public static let maxFileBytes = 32 << 20
    public static let cdnOrigins: Set<String> = ["media0.giphy.com", "media1.giphy.com", "media2.giphy.com", "media3.giphy.com", "media4.giphy.com"]

    let transport: any ProxyHTTPTransport

    public init(transport: any ProxyHTTPTransport) { self.transport = transport }

    /// `isGiphyCdnUrl`: https on one of the media hosts, default port, no credentials.
    public static func isGiphyCdnURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), c.scheme == "https", let host = c.host, cdnOrigins.contains(host),
              c.port == nil, c.user == nil, c.password == nil else { return false }
        return true
    }

    /// `unicodeSlice(query, 0, 50)` when longer than 50 UTF-8 bytes.
    public static func trimmedQuery(_ q: String) -> String {
        var out = String.UnicodeScalarView(), bytes = 0
        for s in q.unicodeScalars {
            let n = String(s).utf8.count
            if bytes + n > maxQueryBytes { break }
            bytes += n
            out.append(s)
        }
        return String(out)
    }

    func url(_ path: String, _ extra: [URLQueryItem]) -> URL {
        var c = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "api_key", value: Self.apiKey), URLQueryItem(name: "rating", value: Self.contentRating),
                        URLQueryItem(name: "bundle", value: Self.contentBundle), URLQueryItem(name: "fields", value: Self.fields)] + extra
        // URLComponents leaves "+" alone in queries; Giphy (like URLSearchParams) reads it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func paging(_ limit: Int, _ offset: Int?) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: "\(limit)")] + (offset.map { [URLQueryItem(name: "offset", value: "\($0)")] } ?? [])
    }

    public func search(_ query: String, limit: Int, offset: Int?) async throws -> PaginatedGifResults {
        try await fetch(url("v1/gifs/search", [URLQueryItem(name: "q", value: Self.trimmedQuery(query))] + paging(limit, offset)))
    }

    public func trending(limit: Int, offset: Int?) async throws -> PaginatedGifResults {
        try await fetch(url("v1/gifs/trending", paging(limit, offset)))
    }

    func fetch(_ url: URL) async throws -> PaginatedGifResults {
        let r = try await transport.request("GET", url, headers: [:], limit: Self.maxResponseBytes)
        guard r.status == 200 else { throw GiphyError.status(r.status) }
        guard r.body.count <= Self.maxResponseBytes else { throw GiphyError.tooLarge(r.body.count) }
        return try Self.parse(r.body)
    }

    // MARK: schema

    struct StringInteger: Decodable {
        var value: Int
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i; return }
            let s = try c.decode(String.self)
            // safeParseInteger: an integer string, nothing else.
            guard let i = Int(s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an integer: \(s)") }
            value = i
        }
    }
    struct Rendition: Decodable { var width: StringInteger; var height: StringInteger; var mp4: String }
    struct Images: Decodable { var original: Rendition; var fixed_width: Rendition }
    struct Gif: Decodable { var id: String; var title: String; var alt_text: String; var images: Images }
    struct Pagination: Decodable { var offset: Int; var total_count: Int; var count: Int }
    struct Meta: Decodable { var status: Int; var response_id: String }
    struct Response: Decodable { var meta: Meta; var pagination: Pagination?; var data: [Gif]? }

    static func media(_ r: Rendition) throws -> GifMedia {
        guard isGiphyCdnURL(r.mp4), let url = URL(string: r.mp4) else { throw GiphyError.invalidResponse("Expected Giphy CDN URL") }
        guard (1 ... 8192).contains(r.width.value), (1 ... 8192).contains(r.height.value) else { throw GiphyError.invalidResponse("dimensions") }
        return GifMedia(url: url, width: r.width.value, height: r.height.value)
    }

    public static func parse(_ data: Data) throws -> PaginatedGifResults {
        let r: Response
        do { r = try JSONDecoder().decode(Response.self, from: data) } catch { throw GiphyError.invalidResponse("\(error)") }
        if r.meta.status == 200 && r.meta.response_id.isEmpty { throw GiphyError.syntheticResponse }
        guard !r.meta.response_id.isEmpty, let p = r.pagination, let items = r.data else { throw GiphyError.invalidResponse("missing fields") }
        let gifs = try items.map { g -> GifResult in
            guard !g.id.isEmpty else { throw GiphyError.invalidResponse("empty id") }
            return GifResult(id: g.id, title: g.title, description: g.alt_text, previewMedia: try media(g.images.fixed_width),
                             attachmentMedia: try media(g.images.original))
        }
        let end = p.offset + p.count
        return PaginatedGifResults(next: end >= p.total_count ? nil : end, gifs: gifs)
    }

    // MARK: files

    static let segmentBuckets = [1 << 20, 500 << 10, 100 << 10, 50 << 10, 10 << 10, 1 << 10]

    struct SegmentRange: Equatable {
        var start: Int, endInclusive: Int, sliceStart: Int, segmentSize: Int, sliceSize: Int
    }

    static func segmentSize(_ contentLength: Int) -> Int { segmentBuckets.first { contentLength >= $0 } ?? contentLength }

    static func segmentRanges(_ contentLength: Int, _ size: Int) -> [SegmentRange] {
        guard contentLength > 0, size > 0 else { return [] }
        return (0 ..< (contentLength + size - 1) / size).map { i in
            var r = SegmentRange(start: size * i, endInclusive: size * i + size - 1, sliceStart: 0, segmentSize: size, sliceSize: size)
            if r.endInclusive >= contentLength {
                r.endInclusive = contentLength - 1
                r.start = contentLength - size
                r.sliceSize = contentLength % size
                r.sliceStart = size - r.sliceSize
            }
            return r
        }
    }

    /// `fetchGiphyFile`: the MP4 at a Giphy CDN URL.
    public func file(_ url: URL) async throws -> Data {
        guard Self.isGiphyCdnURL(url.absoluteString) else { throw GiphyError.blockedURL }
        let head = try await transport.request("HEAD", url, headers: [:], limit: 0)
        guard head.status == 200 else { throw GiphyError.status(head.status) }
        guard let length = head.headers["content-length"].flatMap({ Int($0) }), length > 0 else { throw GiphyError.invalidResponse("Content-Length") }
        guard length <= Self.maxFileBytes else { throw GiphyError.tooLarge(length) }
        let ranges = Self.segmentRanges(length, Self.segmentSize(length))
        // At most four segments in flight.
        var parts = [Data?](repeating: nil, count: ranges.count)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func add() {
                guard next < ranges.count else { return }
                let i = next, r = ranges[i]
                next += 1
                group.addTask { (i, try await segment(url, r, length)) }
            }
            for _ in 0 ..< 4 { add() }
            while let (i, d) = try await group.next() {
                parts[i] = d
                add()
            }
        }
        var out = Data(capacity: length)
        for p in parts { guard let p else { throw GiphyError.invalidResponse("segment missing") }; out.append(p) }
        guard out.count == length else { throw GiphyError.invalidResponse("length") }
        return out
    }

    func segment(_ url: URL, _ r: SegmentRange, _ length: Int) async throws -> Data {
        let resp = try await transport.request("GET", url, headers: ["Range": "bytes=\(r.start)-\(r.endInclusive)"], limit: r.segmentSize)
        guard resp.status == 206 || resp.status == 200 else { throw GiphyError.status(resp.status) }
        guard resp.headers["content-length"] == "\(r.segmentSize)" else { throw GiphyError.invalidResponse("Unexpected Content-Length header") }
        guard resp.headers["content-range"] == "bytes \(r.start)-\(r.endInclusive)/\(length)" else { throw GiphyError.invalidResponse("Unexpected Content-Range header") }
        guard resp.body.count == r.segmentSize else { throw GiphyError.invalidResponse("Unexpected response buffer byte length") }
        return resp.body.suffix(from: resp.body.startIndex + r.sliceStart)
    }
}
