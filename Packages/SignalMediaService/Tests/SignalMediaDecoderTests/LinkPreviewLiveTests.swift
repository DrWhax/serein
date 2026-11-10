// LINK_PREVIEW_LIVE=1: a real page's preview, fetched directly (as the app does) and parsed and
// decoded by the in-process parser and decoder (live network; off by default). Also shows that
// Signal's content proxy refuses ordinary sites.

import Foundation
import Synchronization
import LinkPreviewParser
import Testing
import WebFetch
@testable import LinkPreviewFetcher

@Suite struct LinkPreviewLiveTests {
    @Test func directFetch() async throws {
        guard let url = ProcessInfo.processInfo.environment["LINK_PREVIEW_LIVE"] else { return }
        let href = url.hasPrefix("https://") ? url : "https://www.nu.nl/"
        for proxy in [ContentProxy.direct, .signal] {
            let transport = URLSessionWebTransport(proxy: proxy)
            let log = LogBox()
            let fetcher = LinkPreviewPageFetcher(transport: transport, parser: LinkPreviewParser(), log: { log.add($0) })
            let meta = try await fetcher.page(href)
            print("\(proxy): title \(meta?.title.prefix(60) ?? "-"), image \(meta?.imageHref?.prefix(80) ?? "-"), log \(log.lines)")
            if proxy == .direct {
                #expect(meta?.title.isEmpty == false)
                if let i = meta?.imageHref {
                    let image = try await fetcher.image(i)
                    print("image: \(image?.contentType ?? "-") \(image?.data.count ?? 0) bytes")
                }
            }
        }
    }
}

final class LogBox: Sendable {
    let lock = Mutex<[String]>([])
    func add(_ s: String) { lock.withLock { $0.append(s) } }
    var lines: [String] { lock.withLock { $0 } }
}
