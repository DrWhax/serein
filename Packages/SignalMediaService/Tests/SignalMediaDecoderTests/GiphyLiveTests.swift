// GIPHY_LIVE=1: Giphy trending through Signal's content proxy (live network; off by default).

import Foundation
import Testing
import WebFetch
@testable import GifSearch

@Suite struct GiphyLiveTests {
    @Test func trendingThroughContentProxy() async throws {
        guard ProcessInfo.processInfo.environment["GIPHY_LIVE"] != nil else { return }
        for label in ["system roots"] {
            let giphy = GiphyClient(transport: URLSessionWebTransport(proxy: .signal))
            do {
                let page = try await giphy.trending(limit: 4, offset: nil)
                print("giphy \(label): \(page.gifs.count) gifs, next \(page.next.map(String.init) ?? "-")")
            } catch {
                print("giphy \(label): \(error)")
            }
        }
    }
}
