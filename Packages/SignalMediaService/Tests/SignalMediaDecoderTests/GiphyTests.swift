import Foundation
import Synchronization
import Testing
import MediaXPCInterface
import WebFetch
@testable import GifSearch

/// Serves JSON for the API and byte ranges of `file` for the CDN, recording requests.
final class FakeGiphy: WebTransport {
    struct State { var requests: [(String, URL, [String: String])] = []; var json = Data(); var file = Data(); var lie = false }
    let state = Mutex(State())
    var requests: [(String, URL, [String: String])] { state.withLock { $0.requests } }
    var json: Data { get { state.withLock { $0.json } } set { state.withLock { $0.json = newValue } } }
    var file: Data { get { state.withLock { $0.file } } set { state.withLock { $0.file = newValue } } }
    var lie: Bool { get { state.withLock { $0.lie } } set { state.withLock { $0.lie = newValue } } }

    func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        let (json, file, lie) = state.withLock { s in s.requests.append((method, url, headers)); return (s.json, s.file, s.lie) }
        if url.host == "api.giphy.com" { return WebResponse(status: 200, headers: [:], body: json, url: url) }
        if method == "HEAD" { return WebResponse(status: 200, headers: ["content-length": "\(file.count)"], body: Data(), url: url) }
        let spec = headers["Range"]!.dropFirst("bytes=".count).split(separator: "-").map { Int($0)! }
        let end = min(spec[1], file.count - 1)
        let body = file.subdata(in: spec[0] ..< end + 1)
        let range = lie ? "bytes 0-\(end)/\(file.count)" : "bytes \(spec[0])-\(end)/\(file.count)"
        return WebResponse(status: 206, headers: ["content-length": "\(body.count)", "content-range": range], body: body, url: url)
    }
}

@Suite struct GiphyTests {
    static func item(_ id: String, mp4: String = "https://media2.giphy.com/media/x/200w.mp4", width: String = "\"200\"") -> String {
        """
        {"id":"\(id)","title":"T \(id)","alt_text":"A \(id)","images":{"original":{"width":480,"height":"270","mp4":"https://media0.giphy.com/media/x/giphy.mp4"},
         "fixed_width":{"width":\(width),"height":"113","mp4":"\(mp4)"}}}
        """
    }
    static func page(_ items: [String], offset: Int = 0, total: Int = 100, responseID: String = "abc") -> Data {
        Data("""
        {"data":[\(items.joined(separator: ","))],"pagination":{"offset":\(offset),"total_count":\(total),"count":\(items.count)},"meta":{"status":200,"msg":"OK","response_id":"\(responseID)"}}
        """.utf8)
    }

    @Test func parsesResults() throws {
        let r = try GiphyClient.parse(Self.page([Self.item("a"), Self.item("b")], offset: 10, total: 100))
        #expect(r.next == 12 && r.gifs.map(\.id) == ["a", "b"])
        #expect(r.gifs[0].previewMedia == GifMedia(url: URL(string: "https://media2.giphy.com/media/x/200w.mp4")!, width: 200, height: 113))
        #expect(r.gifs[0].attachmentMedia.width == 480 && r.gifs[0].description == "A a")
        #expect(try GiphyClient.parse(Self.page([Self.item("a")], offset: 99, total: 100)).next == nil)
    }

    @Test func rejectsBadResponses() {
        #expect(throws: GiphyError.syntheticResponse) { try GiphyClient.parse(Data(#"{"meta":{"status":200,"response_id":""}}"#.utf8)) }
        for mp4 in ["https://evil.example/x.mp4", "http://media1.giphy.com/x.mp4", "https://media1.giphy.com:8443/x.mp4", "https://u@media1.giphy.com/x.mp4",
                    "https://media5.giphy.com/x.mp4", "https://media1.giphy.com.evil.example/x.mp4"] {
            #expect(throws: GiphyError.self, "\(mp4)") { try GiphyClient.parse(Self.page([Self.item("a", mp4: mp4)])) }
        }
        #expect(throws: GiphyError.self) { try GiphyClient.parse(Self.page([Self.item("a", width: "\"20px\"")])) }
        #expect(throws: GiphyError.self) { try GiphyClient.parse(Self.page([Self.item("a", width: "0")])) }
        #expect(throws: GiphyError.self) { try GiphyClient.parse(Self.page([Self.item("")])) }
        #expect(throws: GiphyError.self) { try GiphyClient.parse(Data("[]".utf8)) }
    }

    @Test func buildsRequests() async throws {
        let t = FakeGiphy()
        t.json = Self.page([Self.item("a")])
        let c = GiphyClient(transport: t)
        _ = try await c.search("c++ & 🎉", limit: 10, offset: nil)
        _ = try await c.trending(limit: 30, offset: 10)
        let q = t.requests.map { URLComponents(url: $0.1, resolvingAgainstBaseURL: false)! }
        #expect(q[0].path == "/v1/gifs/search" && q[1].path == "/v1/gifs/trending")
        let items = Dictionary(uniqueKeysWithValues: q[0].queryItems!.map { ($0.name, $0.value!) })
        #expect(items["q"] == "c++ & 🎉" && items["limit"] == "10" && items["offset"] == nil && items["rating"] == "pg-13" && items["bundle"] == "messaging_non_clips")
        #expect(q[0].percentEncodedQuery!.contains("q=c%2B%2B%20%26%20%F0%9F%8E%89"))
        #expect(q[1].queryItems!.contains(URLQueryItem(name: "offset", value: "10")))
        // 50 UTF-8 bytes of whole code points.
        #expect(GiphyClient.trimmedQuery(String(repeating: "a", count: 49) + "€") == String(repeating: "a", count: 49))
        #expect(GiphyClient.trimmedQuery(String(repeating: "€", count: 20)).utf8.count == 48)
    }

    @Test func segmentRanges() {
        #expect(GiphyClient.segmentSize(5_000_000) == 1 << 20 && GiphyClient.segmentSize(1023) == 1023 && GiphyClient.segmentSize(60_000) == 50 << 10)
        for length in [1, 1023, 1024, 1025, 2047, 2048, 2049, 5_000_000, (1 << 20) * 3 - 1] {
            let size = GiphyClient.segmentSize(length)
            let ranges = GiphyClient.segmentRanges(length, size)
            // Every request is a whole segment within the file, and the slices tile it.
            var covered = 0
            for r in ranges {
                #expect(r.endInclusive - r.start + 1 == size && r.start >= 0 && r.endInclusive < length, "\(length): \(r)")
                #expect(r.start + r.sliceStart == covered && r.sliceSize == size - r.sliceStart, "\(length): \(r)")
                covered += r.sliceSize
            }
            #expect(covered == length, "\(length)")
        }
    }

    @Test func fetchesFilesInSegments() async throws {
        let t = FakeGiphy()
        t.file = Data((0 ..< 2047 + 3 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let c = GiphyClient(transport: t)
        let url = URL(string: "https://media3.giphy.com/media/x/giphy.mp4")!
        #expect(try await c.file(url) == t.file)
        let gets = t.requests.filter { $0.0 == "GET" }
        #expect(gets.count == 5 && gets.allSatisfy { $0.2["Range"] != nil })
        t.lie = true
        await #expect(throws: GiphyError.self) { try await c.file(url) }
        await #expect(throws: GiphyError.blockedURL) { try await c.file(URL(string: "https://example.com/x.mp4")!) }
    }
}
