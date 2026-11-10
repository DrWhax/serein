// The fetch-level cases of upstream's linkPreviewFetch_test against a fake transport, for the
// fetcher service's logic (LinkPreviewPageFetcher) with the in-process parser.

import CodecCore
import EncodePNG
import Foundation
import LinkPreviewParser
import MediaXPCInterface
import Synchronization
import Testing
import WebFetch
@testable import LinkPreviewFetcher

/// A scripted web: URL → response; records requests.
final class FakeTransport: WebTransport {
    struct Page: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        static func html(_ head: String, type: String = "text/html; charset=utf-8") -> Page {
            Page(headers: ["content-type": type], body: Data("<!doctype html><html><head>\(head)</head><body></body></html>".utf8))
        }
    }
    let pages: [String: Page]
    let log = Mutex<[(URL, [String: String])]>([])
    var requests: [(URL, [String: String])] { log.withLock { $0 } }

    init(_ pages: [String: Page]) { self.pages = pages }

    func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        log.withLock { $0.append((url, headers)) }
        guard let page = pages[url.absoluteString] else { throw URLError(.cannotConnectToHost) }
        return WebResponse(status: page.status, headers: page.headers, body: page.body.prefix(limit + 1), url: url)
    }
}

struct LinkPreviewFetchTests {
    let site = "https://site.signalsafe.app"

    func meta(_ t: FakeTransport, _ path: String = "/") async -> FetchedLinkPreview? {
        try? await LinkPreviewPageFetcher(transport: t, parser: LinkPreviewParser()).page(site + path)
    }

    @Test func pagesAndHeaders() async {
        let t = FakeTransport([site + "/": .html("<meta property=\"og:title\" content=\"test title\"><meta property=\"og:image\" content=\"image.jpg\">"
                                                 + "<meta property=\"og:published_time\" content=\"2020-04-20T12:34:56.009Z\">")])
        let m = await meta(t)
        #expect(m?.title == "test title" && m?.imageHref == site + "/image.jpg" && m?.date == 1_587_386_096_009)
        #expect(t.requests.first?.1["User-Agent"] == "WhatsApp/2" && t.requests.first?.1["Accept"] == "text/html,application/xhtml+xml")
        // Not HTML, not inline, too short, not 2xx, uppercase content type.
        let bad = FakeTransport([site + "/json": .init(headers: ["content-type": "application/json"], body: Data("{\"title\":1}".utf8)),
                                 site + "/dl": .init(headers: ["content-type": "text/html", "content-disposition": "attachment; filename=a.html"],
                                                     body: Data("<title>x</title>".utf8)),
                                 site + "/short": .init(headers: ["content-type": "text/html", "content-length": "7"], body: Data("<title>".utf8)),
                                 site + "/404": .init(status: 404, headers: ["content-type": "text/html"], body: Data("<title>x</title>".utf8)),
                                 site + "/caps": .init(headers: ["content-type": "TEXT/HTML; CHARSET=UTF-8", "content-disposition": "inline"],
                                                       body: Data("<title>caps</title>".utf8))])
        for p in ["/json", "/dl", "/short", "/404"] { #expect(await meta(bad, p) == nil, "\(p)") }
        #expect(await meta(bad, "/caps")?.title == "caps")
    }

    @Test func redirects() async {
        for status in [301, 302, 303, 307, 308] {
            let t = FakeTransport([site + "/a": .init(status: status, headers: ["location": "/b"]), site + "/b": .html("<title>moved</title><meta property=\"og:image\" content=\"i.png\">")])
            let m = await meta(t, "/a")
            #expect(m?.title == "moved" && m?.imageHref == site + "/i.png", "\(status)")   // relative to the final URL
        }
        let t = FakeTransport([site + "/nolocation": .init(status: 301),
                               site + "/insecure": .init(status: 302, headers: ["location": "http://site.signalsafe.app/x"]),
                               site + "/excluded": .init(status: 302, headers: ["location": "https://localhost/x"]),
                               site + "/loop1": .init(status: 302, headers: ["location": "/loop2"]), site + "/loop2": .init(status: 302, headers: ["location": "/loop1"])])
        for p in ["/nolocation", "/insecure", "/excluded", "/loop1"] { #expect(await meta(t, p) == nil, "\(p)") }
        var chain: [String: FakeTransport.Page] = [:]
        for i in 0..<21 { chain[site + "/r\(i)"] = .init(status: 302, headers: ["location": "/r\(i + 1)"]) }
        chain[site + "/r21"] = .html("<title>too far</title>")
        #expect(await meta(FakeTransport(chain), "/r0") == nil)
    }

    @Test func sizesAndImages() async throws {
        // Only the first 1000 KiB of HTML is read.
        let padding = String(repeating: "a", count: LinkPreviewPageFetcher.maxHTMLBytes)
        let big = FakeTransport([site + "/": .init(headers: ["content-type": "text/html"],
                                                   body: Data("<title>foo bar</title><p>\(padding)</p><meta property=\"og:description\" content=\"should be ignored\">".utf8))])
        let m = await meta(big)
        #expect(m?.title == "foo bar" && m?.description == nil)
        // A link straight to an image: its bytes come back unread (the app's media decoder
        // checks and re-encodes them).
        let png = Data(PNGEncoder.encode(PixelBuffer(width: 4, height: 4, rgba: [UInt8](repeating: 200, count: 64))))
        let gif = Data("GIF89a\u{1}\u{0}\u{1}\u{0}".utf8)
        let t = FakeTransport([site + "/pic.png": .init(headers: ["content-type": "image/png"], body: png),
                               site + "/anim.gif": .init(headers: ["content-type": "image/gif"], body: gif),
                               site + "/fake.png": .init(headers: ["content-type": "image/png"], body: Data("not a png at all".utf8)),
                               site + "/huge.png": .init(headers: ["content-type": "image/png"], body: png + Data(count: FetchedImage.maxBytes)),
                               site + "/text": .init(headers: ["content-type": "text/plain"], body: png)])
        let direct = await meta(t, "/pic.png")
        #expect(direct?.title == "pic.png" && direct?.image == FetchedImage(data: png, contentType: "image/png"))
        let fetcher = LinkPreviewPageFetcher(transport: t, parser: LinkPreviewParser())
        #expect(try await fetcher.image(site + "/anim.gif")?.data == gif)
        #expect(try await fetcher.image(site + "/fake.png")?.data == Data("not a png at all".utf8), "not decoded here")
        for p in ["/huge.png", "/text"] { #expect(try await fetcher.image(site + p) == nil, "\(p)") }
    }

    @Test func dates() {
        #expect(LinkPreviewPageFetcher.parseDate("2020-04-20T12:34:56.009Z") == 1_587_386_096_009)
        #expect(LinkPreviewPageFetcher.parseDate("2020-04-20T12:34:56Z") == 1_587_386_096_000 && LinkPreviewPageFetcher.parseDate("3001-01-01") == nil)
        #expect(LinkPreviewPageFetcher.parseDate("Mon, 20 Apr 2020 12:34:56 GMT") == 1_587_386_096_000 && LinkPreviewPageFetcher.parseDate("soon") == nil)
    }
}

