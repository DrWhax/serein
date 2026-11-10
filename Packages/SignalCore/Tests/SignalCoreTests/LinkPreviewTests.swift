// Link previews: ts/types/LinkPreview rules, the image step (the media decoder), and the
// fetcher's logic through a CONNECT proxy (the harness's stand-in) to an HTTPS site. The
// fetch-level cases are in SignalMediaService's LinkPreviewFetcherTests.

import Foundation
import LinkPreviewFetcher
import LinkPreviewParser
import GRDB
import WebFetch
import Synchronization
import MediaXPCInterface
import SignalMediaDecoder
import SignalProtos
import SignalText
import Testing
@testable import SignalCore

struct LinkPreviewRuleTests {
    @Test func whatGetsAPreview() {
        #expect(LinkPreviewRules.shouldPreviewHref("https://signal.org/blog"))
        #expect(!LinkPreviewRules.shouldPreviewHref("http://signal.org/blog"))
        for host in ["localhost", "example.com", "a.example.org", "x.onion", "foo.test", "debuglogs.org", "invalid"] {
            #expect(!LinkPreviewRules.shouldPreviewHref("https://\(host)/x"), "\(host)")
        }
        #expect(!LinkPreviewRules.shouldPreviewHref("https://user:pw@signal.org/"))
        #expect(!LinkPreviewRules.shouldPreviewHref("https://signal/"))
        #expect(!LinkPreviewRules.shouldPreviewHref("https://xn--sgnal-m3a.org/"))   // mixed-script host
        #expect(LinkPreviewRules.findLinks("see https://signal.org/a and https://signal.org/b.") == ["https://signal.org/a", "https://signal.org/b"])
        #expect(LinkPreviewRules.findLinks("evil \u{202E}https://signal.org/") == [])
        // The caret inside a link being typed leaves it out.
        #expect(LinkPreviewRules.findLinks("https://signal.org/abc more", caretLocation: 10) == [])
        #expect(LinkPreviewRules.findLinks("https://signal.org/abc", caretLocation: 22) == ["https://signal.org/abc"])
        #expect(LinkPreviewRules.isValidLinkPreview(url: "https://signal.org/a", urlsInBody: ["https://signal.org/a"]))
        #expect(!LinkPreviewRules.isValidLinkPreview(url: "https://signal.org/b", urlsInBody: ["https://signal.org/a"]))
        #expect(LinkPreviewRules.isValidLinkPreview(url: "https://signal.org/b", urlsInBody: [], isStory: true))
        let id = String(repeating: "ab", count: 16), key = String(repeating: "cd", count: 32)
        #expect(LinkPreviewRules.stickerPack("https://signal.art/addstickers/#pack_id=\(id)&pack_key=\(key)")?.packId == id)
        #expect(LinkPreviewRules.stickerPack("https://signal.art/addstickers/#pack_id=\(id)") == nil)
        #expect(LinkPreviewRules.stickerPack("https://evil.art/addstickers/#pack_id=\(id)&pack_key=\(key)") == nil)
        #expect(LinkPreviewRules.groupInviteFragment("https://signal.group/#CjQKIA") == "CjQKIA")
        #expect(LinkPreviewRules.isCallLink("https://signal.link/call/#key=bcdf-ghkm") && !LinkPreviewRules.isCallLink("https://signal.link/other#k"))
    }
}

struct LinkPreviewImageTests {
    /// `processImageResponse`: an image that does not decode is no image; GIFs are kept.
    @Test func imagesGoThroughTheDecoder() async throws {
        let media = MediaDecoder()
        #expect(await LinkPreviewFetch.processImage(FetchedImage(data: Data("not a png at all".utf8), contentType: "image/png"), media: media) == nil)
        let png = AttachmentFlowTests.png()
        let out = await LinkPreviewFetch.processImage(FetchedImage(data: png, contentType: "image/png"), media: media)
        #expect(out?.contentType == "image/png" || out?.contentType == "image/jpeg")
        let gif = try StickerFixtures.file("GIFTestSuite/255-codes.gif")
        #expect(await LinkPreviewFetch.processImage(FetchedImage(data: gif, contentType: "image/gif"), media: media)?.data == gif)
        #expect(await LinkPreviewFetch.processImage(FetchedImage(data: png, contentType: "image/tiff"), media: media) == nil)
    }
}

@Suite(.serialized) struct LinkPreviewFlowTests {
    static let strings = LinkPreviewStrings(stickerPackDescription: { "Sticker pack by \($0)" }, groupDescription: { "\($0) members" },
                                            unknownGroup: "Unknown group", callLinkTitle: "Signal call", callLinkDescription: "Use this link to join a Signal call")

    func service(_ c: LinkedClient) async throws -> LinkPreviewService {
        let png = AttachmentFlowTests.png()
        let html = "<!doctype html><head><title>fallback</title><meta property=\"og:title\" content=\"Tea &amp; biscuits\">"
            + "<meta property=\"og:description\" content=\"A proper cuppa\"><meta property=\"og:image\" content=\"/img/cup.png\"></head>"
        func route(_ status: Int, _ headers: [String: String], _ body: Data) -> [String: any Sendable] {
            ["status": status, "headers": headers, "body": body.base64EncodedString()]
        }
        let routes: [String: any Sendable] = [
            "news.signalsafe.app/tea": route(200, ["Content-Type": "text/html; charset=utf-8"], Data(html.utf8)),
            "news.signalsafe.app/img/cup.png": route(200, ["Content-Type": "image/png"], png),
            "news.signalsafe.app/old": route(301, ["Location": "https://news.signalsafe.app/tea"], Data()),
        ]
        let r = try await c.server.json("setPreviewSite", ["routes": routes])
        let port = try #require(r["proxyPort"] as? Int)
        // The fetcher service's logic, in process: through the harness's CONNECT proxy, pages
        // parsed by the in-process parser.
        let transport = URLSessionWebTransport(proxy: .custom(host: "127.0.0.1", port: port), rootCertificatesDER: c.endpoints.rootCertificatesDER)
        let fetcher = LinkPreviewPageFetcher(transport: transport, parser: LinkPreviewParser())
        return LinkPreviewService(fetcher: fetcher, media: MediaDecoder(), stickers: c.stickers, groups: c.groups, strings: Self.strings)
    }

    @Test func pagePreviewThroughTheProxyAndSend() async throws {
        try await LinkedClient.with { c in
            let previews = try await service(c)
            let draft = try #require(await previews.preview(for: "https://news.signalsafe.app/old"))
            #expect(draft.title == "Tea & biscuits" && draft.description == "A proper cuppa" && draft.domain == "news.signalsafe.app")
            let image = try #require(draft.image)
            #expect(image.contentType == "image/png" || image.contentType == "image/jpeg")
            let log = try await c.server.json("previewLog")
            #expect((log["connects"] as? [String])?.allSatisfy { $0 == "news.signalsafe.app:443" } == true && (log["connects"] as? [String])?.isEmpty == false)
            let paths = (log["requests"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
            #expect(paths == ["/old", "/tea", "/img/cup.png"])
            #expect((log["requests"] as? [[String: Any]])?.allSatisfy { $0["userAgent"] as? String == "WhatsApp/2" } == true)

            // Sent with a message: the phone-side decrypt of the image matches what we stored.
            let body = "look https://news.signalsafe.app/old"
            let sent = try await c.messenger.sendMessage(body, attachments: [], preview: draft, to: c.aliceAci)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let p = try #require((m["preview"] as? [[String: Any]])?.first)
            #expect(p["url"] as? String == "https://news.signalsafe.app/old" && p["title"] as? String == "Tea & biscuits" && p["description"] as? String == "A proper cuppa")
            let i = try #require(p["image"] as? [String: Any])
            let fetched = try await c.server.json("fetchAndDecryptAttachment", ["cdnKey": i["cdnKey"] as! String, "key": i["key"] as! String,
                                                                                "digest": i["digest"] as! String, "size": i["size"] as! Int])
            #expect(Data(base64Encoded: fetched["plaintext"] as! String) == image.data && i["width"] as? Int != nil)
            let stored = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT json ->> '$.preview' FROM messages WHERE id = ?", arguments: [sent.messageId]) }
            #expect(stored?.contains("news.signalsafe.app") == true)
            // The timeline carries it, with its stored image.
            let conversation = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [sent.messageId]) }
            let timeline = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation ?? "", limit: 10) }
            let shown = try #require(timeline.first { $0.id == sent.messageId }?.previews.first)
            #expect(shown.url == "https://news.signalsafe.app/old" && shown.title == "Tea & biscuits" && shown.domain == "news.signalsafe.app")
            #expect(shown.image?.isDownloaded == true && shown.image?.contentType == image.contentType)
        }
    }

    @Test func receivedPreviewsAreValidated() async throws {
        try await LinkedClient.with { c in
            let t = TestClock.next()
            try await c.server.call("sendTextWithPreview", ["text": "read https://signal.org/blog/ please", "timestamp": t, "previews": [
                ["url": "https://signal.org/blog/", "title": "Signal blog", "description": "News", "date": 1_587_386_096_009],
                ["url": "https://evil.signalsafe.app/not-in-body", "title": "Spoofed"],
                ["url": "http://signal.org/blog/", "title": "Insecure"],
            ] as [[String: any Sendable]]])
            _ = try await c.log.waitFor { if case .message(_, _, _, _, let ts, _, _, _) = $0 { return ts == t } else { return false } }
            let json = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT json ->> '$.preview' FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) }
            let list = try #require(try JSONSerialization.jsonObject(with: Data((json ?? "[]").utf8)) as? [[String: Any]])
            #expect(list.count == 1 && list[0]["title"] as? String == "Signal blog" && list[0]["domain"] as? String == "signal.org"
                    && list[0]["date"] as? Int64 == 1_587_386_096_009)
            let conversation = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT conversationId FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) }
            let timeline = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: conversation ?? "", limit: 10) }
            let shown = try #require(timeline.first { $0.sentAt == Int64(t) })
            #expect(shown.previews.map(\.url) == ["https://signal.org/blog/"] && shown.previews[0].date == 1_587_386_096_009 && shown.previews[0].image == nil)
        }
    }

    @Test func stickerPackAndGroupLinkPreviews() async throws {
        try await LinkedClient.with { c in
            let previews = try await service(c)
            let r = try await c.server.json("createStickerPack", ["images": [try StickerFixtures.webp().base64EncodedString()], "title": "Frogs", "author": "Pond"])
            let packId = r["packId"] as! String, key = Data(base64Encoded: r["packKey"] as! String)!
            let sticker = try #require(await previews.preview(for: "https://signal.art/addstickers/#pack_id=\(packId)&pack_key=\(key.hexString)"))
            let webp = try StickerFixtures.webp()
            #expect(sticker.title == "Frogs" && sticker.description == "Sticker pack by Pond" && sticker.isStickerPack && sticker.image?.data == webp)
            // Nothing was stored for a preview of a pack we do not have.
            #expect(try await c.database.pool.read { try Stickers.status($0, packId) } == nil)

            let g = try await c.server.json("createGroup", ["title": "Tea party", "members": ["alice"], "link": "any"])
            let link = GroupLink(masterKey: Data(base64Encoded: g["masterKey"] as! String)!, inviteLinkPassword: Data(base64Encoded: g["inviteLinkPassword"] as! String)!)
            let group = try #require(await previews.preview(for: link.url))
            #expect(group.title == "Tea party" && group.description == "1 members")
            let call = try #require(await previews.preview(for: "https://signal.link/call/#key=bcdf-ghkm-mnpq"))
            #expect(call.isCallLink && call.title == "Signal call")
        }
    }
}
