// The web-facing services over XPC, in process (anonymous listeners): the app's fetcher client
// gets the parser's endpoint, the fetcher fetches (a scripted web) and has the page parsed
// through that endpoint; a code-signing requirement nobody meets is refused on either side.
// And GIF search through its service, re-validated by the client.

import CodecCore
import EncodePNG
import Foundation
import GifSearch
import LinkPreviewFetcher
import LinkPreviewParser
import MediaXPCInterface
import Testing
import WebFetch

@Suite struct WebServicesXPCTests {
    static let site = "https://site.signalsafe.app"

    final class Services {
        let parser: LinkPreviewParserServiceDelegate
        let parserListener = NSXPCListener.anonymous()
        let fetcherDelegate: LinkPreviewFetcherListenerDelegate
        let fetcherListener = NSXPCListener.anonymous()

        init(transport: any WebTransport, fetcherPeerAtParser: String? = nil) {
            parser = LinkPreviewParserServiceDelegate(appPeer: nil, fetcherPeer: fetcherPeerAtParser)
            parserListener.delegate = parser
            parserListener.resume()
            fetcherDelegate = LinkPreviewFetcherListenerDelegate(handler: LinkPreviewFetcherXPCHandler(transport: transport, parserPeer: nil), appPeer: nil)
            fetcherListener.delegate = fetcherDelegate
            fetcherListener.resume()
        }

        func client(fetcherPeer: String? = nil) -> LinkPreviewFetcherClient {
            let f = fetcherListener.endpoint, p = parserListener.endpoint
            return LinkPreviewFetcherClient(timeout: .seconds(20), fetcherPeer: fetcherPeer, parserPeer: nil,
                                            fetcherConnection: { NSXPCConnection(listenerEndpoint: f) }, parserConnection: { NSXPCConnection(listenerEndpoint: p) })
        }
    }

    static func web() -> FakeTransport {
        let png = Data(PNGEncoder.encode(PixelBuffer(width: 4, height: 4, rgba: [UInt8](repeating: 99, count: 64))))
        return FakeTransport([site + "/": .html("<title>hello</title><meta property=\"og:image\" content=\"/i.png\">"
                                                + "<meta property=\"article:published_time\" content=\"2020-04-20T12:34:56Z\">"),
                              site + "/i.png": .init(headers: ["content-type": "image/png"], body: png)])
    }

    @Test func pageAndImageThroughTheServices() async throws {
        let s = Services(transport: Self.web())
        let client = s.client()
        let page = try await client.page(Self.site + "/")
        #expect(page?.title == "hello" && page?.imageHref == Self.site + "/i.png" && page?.date == 1_587_386_096_000)
        let image = try await client.image(Self.site + "/i.png")
        #expect(image?.contentType == "image/png" && image?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(try await client.page(Self.site + "/missing") == nil)
    }

    @Test func peersThatDoNotMeetTheRequirementAreRefused() async throws {
        let impossible = "identifier \"org.signalsafe.nobody\" and anchor apple"
        // The app's side: the fetcher is not signed as required.
        let s = Services(transport: Self.web())
        await #expect(throws: (any Error).self) { try await s.client(fetcherPeer: impossible).page(Self.site + "/") }
        // The parser's side: only the fetcher may send HTML; anything else gets no page.
        let strict = Services(transport: Self.web(), fetcherPeerAtParser: impossible)
        #expect(try await strict.client().page(Self.site + "/") == nil)
    }

    @Test func gifSearchThroughItsService() async throws {
        let giphy = FakeGiphy()
        giphy.json = GiphyTests.page([GiphyTests.item("a"), GiphyTests.item("b")])
        let delegate = GifSearchListenerDelegate(handler: GifSearchXPCHandler(giphy: GiphyClient(transport: giphy)), appPeer: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        let client = GifSearchClient(timeout: .seconds(20), peer: nil) { NSXPCConnection(listenerEndpoint: endpoint) }
        let page = try await client.trending(limit: 2, offset: nil)
        #expect(page.gifs.map(\.id) == ["a", "b"] && page.gifs[0].previewMedia.url.host == "media2.giphy.com")
        giphy.file = Data((0..<3000).map { UInt8($0 & 0xFF) })
        #expect(try await client.file(URL(string: "https://media2.giphy.com/media/x/200w.mp4")!) == giphy.file)
        await #expect(throws: (any Error).self) { try await client.file(URL(string: "https://evil.example/x.mp4")!) }
        listener.invalidate()
    }
}
