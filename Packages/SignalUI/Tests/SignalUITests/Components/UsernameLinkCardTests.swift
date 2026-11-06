// The saved username card: a 1272×1728 (3x of 424×576) PNG at 300 dpi; text wrapping.

import Foundation
import Testing
@testable import SignalUI
import SignalI18n

@MainActor
@Suite struct UsernameLinkCardTests {
    @Test func pngIsThreeTimesTheCardAt300dpi() throws {
        let png = try #require(UsernameLinkCard.png(link: "https://signal.me/#eu/abcdefghijklmnop", username: "alice.42", color: .blue,
                                                      i18n: Localizer(locale: "en")))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func be32(_ i: Int) -> Int { Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3]) }
        #expect(be32(16) == 1272 && be32(20) == 1728)
        // pHYs right after IHDR: 11811 px/m (300 dpi), unit metre.
        #expect(String(decoding: png[37..<41], as: UTF8.self) == "pHYs" && be32(41) == 11_811 && png[49] == 1)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"] {
            try Data(png).write(to: URL(fileURLWithPath: dir).appendingPathComponent("username-card.png"))
        }
    }

    @Test func splitsLikeUpstream() {
        let style = UsernameLinkCard.usernameStyle
        #expect(UsernameLinkCard.split("short.01", words: false, maxWidth: 222, style: style) == ["short.01"])
        let long = UsernameLinkCard.split(String(repeating: "w", count: 30) + ".99", words: false, maxWidth: 222, style: style)
        #expect(long.count >= 2 && long.allSatisfy { UsernameLinkCard.width($0, style) <= 222 } && long.joined() == String(repeating: "w", count: 30) + ".99")
        let hint = UsernameLinkCard.split("Only share your QR code and link with people you trust. When shared others will be able to view your username",
                                          words: true, maxWidth: 296, style: UsernameLinkCard.hintStyle)
        #expect(hint.count >= 2 && hint.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
    }
}
