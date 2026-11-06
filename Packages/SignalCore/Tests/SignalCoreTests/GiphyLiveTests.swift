// GIPHY_LIVE=1: Giphy trending through Signal's content proxy (live network; off by default).

import Foundation
import Testing
@testable import SignalCore

@Suite struct GiphyLiveTests {
    @Test func trendingThroughContentProxy() async throws {
        guard ProcessInfo.processInfo.environment["GIPHY_LIVE"] != nil else { return }
        for (label, roots) in [("system roots", [Data]()), ("signal roots", try SignalEnvironment.production.endpoints.rootCertificatesDER)] {
            let giphy = GiphyClient(transport: URLSessionLinkPreviewTransport(proxy: .signal, rootCertificatesDER: roots))
            do {
                let page = try await giphy.trending(limit: 4, offset: nil)
                print("giphy \(label): \(page.gifs.count) gifs, next \(page.next.map(String.init) ?? "-")")
            } catch {
                print("giphy \(label): \(error)")
            }
        }
    }
}
