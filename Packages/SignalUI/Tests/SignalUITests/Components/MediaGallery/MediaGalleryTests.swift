// ts/components/conversation/media-gallery/*.dom.stories.tsx

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct MediaGalleryEmptyStateTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, tab) in [("default", MediaGalleryTab.media), ("media", .media), ("audio", .audio), ("documents", .documents), ("links", .links)] {
            try Snapshot.assertMatches(MediaGalleryEmptyState(tab: tab).frame(width: 1200, height: 900),
                                       story: "components-conversation-mediagallery-emptystate--\(name)", theme: theme)
        }
    }
}

/// Fixture helpers: "13.5 MB" → bytes, "Nov 4" → a date in the capture's year (2026, London).
enum MediaGalleryFixture {
    static func bytes(_ text: String) -> Int {
        let parts = text.split(separator: " ")
        let v = Double(parts[0]) ?? 0
        let unit: Double = switch parts.last { case "kB": 1_000; case "MB": 1_000_000; case "GB": 1_000_000_000; default: 1 }
        return Int((v * unit).rounded())
    }
    static func date(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "MMM d yyyy HH:mm"
        return f.date(from: "\(text) 2026 12:00") ?? .now
    }
    static func attachment(_ name: String, contentType: String = "application/octet-stream", size: String, state: Int) -> MessageAttachment {
        var a = MessageAttachment(contentType: contentType, fileName: name, size: bytes(size), width: nil, height: nil)
        a.hasUrl = state == 0
        a.pending = state == 2
        return a
    }
}

@MainActor
@Suite struct DocumentListItemTests {
    @Test(arguments: ["light", "dark"])
    func multiple(theme: String) throws {
        let view = VStack(spacing: 0) {
            ForEach(Array(DocumentListItemFixtures.rows.enumerated()), id: \.offset) { i, r in
                DocumentListItem(attachment: MediaGalleryFixture.attachment(r.0, size: r.1, state: r.3),
                                 message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.2)), authorTitle: "Alice")
            }
        }
        .frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-mediagallery-documentlistitem--multiple", theme: theme)
    }
}

@MainActor
@Suite struct AudioListItemTests {
    @Test(arguments: ["light", "dark"])
    func multiple(theme: String) throws {
        let view = VStack(spacing: 0) {
            ForEach(Array(AudioListItemFixtures.rows.enumerated()), id: \.offset) { i, r in
                let parts = r.1.components(separatedBy: " · ")
                let d = parts[2].split(separator: ":").compactMap { Double($0) }
                AudioListItem(attachment: MediaGalleryFixture.attachment(r.0, contentType: "audio/mp3", size: parts[0], state: r.3),
                              message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.2)), authorTitle: "Alice",
                              isVoiceMessage: parts[1] == "Voice Message", duration: d.count == 2 ? d[0] * 60 + d[1] : 0,
                              peaks: r.3 == 0 ? r.4.map { $0 / 22 } : nil, isPlayed: !r.5)
            }
        }
        .frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-mediagallery-audiolistitem--multiple", theme: theme)
    }
}

@MainActor
@Suite struct LinkPreviewItemTests {
    @Test(arguments: ["light", "dark"])
    func multiple(theme: String) throws {
        let cat = fixturePNG("cat-screenshot-3x4.png")
        let view = VStack(spacing: 0) {
            ForEach(Array(LinkPreviewItemFixtures.rows.enumerated()), id: \.offset) { i, r in
                var p = LinkPreview(url: "https://signal.org/", domain: "signal.org", title: "Signal", description: "description")
                let _ = {
                    if r.1 {
                        var a = MessageAttachment(contentType: "image/png", fileName: nil, size: 1000, width: 400, height: 300)
                        a.image = cat
                        p.image = a
                    }
                }()
                LinkPreviewItem(preview: p, message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.0)), authorTitle: "Alice")
            }
        }
        .frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-mediagallery-linkpreviewitem--multiple", theme: theme)
    }
}

@MainActor
@Suite struct GalleryContactListItemTests {
    @Test(arguments: ["light", "dark"])
    func multiple(theme: String) throws {
        let cat = fixturePNG("cat-screenshot-3x4.png")
        let view = VStack(spacing: 0) {
            ForEach(Array(GalleryContactListItemFixtures.rows.enumerated()), id: \.offset) { i, r in
                let avatar: MessageAttachment? = r.2 < 0 ? nil : {
                    var a = MessageAttachment(contentType: "image/png", fileName: "x.png", size: 1000, width: 400, height: 300)
                    a.hasUrl = r.2 == 0
                    a.pending = r.2 == 2
                    a.image = cat
                    return a
                }()
                GalleryContactListItem(name: "Bob", avatar: avatar, message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.0)),
                                       authorTitle: "Alice")
            }
        }
        .frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-mediagallery-contactlistitem--multiple", theme: theme)
    }
}

/// MediaGridItem.dom.stories.tsx: alone, a tile is as wide (and tall) as its image.
@MainActor
@Suite struct MediaGridItemTests {
    static let hash = "LDA,FDBnm+I=p{tkIUI;~UkpELV]"

    static func item(_ contentType: String, size: Int = 123, url: String? = nil, screenshot: String? = nil, pending: Bool = false,
                     downloaded: Int? = nil, gif: Bool = false, hasUrl: Bool? = nil) -> MessageAttachment {
        var a = MessageAttachment(contentType: contentType, fileName: nil, size: size, width: nil, height: nil)
        a.hasUrl = hasUrl ?? (url != nil)
        a.image = fixtureByURL(url)
        a.screenshot = fixtureByURL(screenshot)
        a.pending = pending
        a.totalDownloaded = downloaded
        a.isGifFlag = gif
        a.blurHash = BlurHashImage.trusted(hash, intrinsicWidth: nil, intrinsicHeight: nil)
        return a
    }

    static var stories: [(String, MessageAttachment)] {
        [
            ("image", item("image/jpeg", url: "/fixtures/kitten-1-64-64.jpg")),
            ("wide-image", item("image/jpeg", url: "/fixtures/wide.jpg")),
            ("tall-image", item("image/jpeg", url: "/fixtures/snow.jpg")),
            ("video", item("video/mp4", size: 1024, screenshot: "/fixtures/kitten-2-64-64.jpg", hasUrl: true)),
            ("gif", item("video/mp4", size: 1024, screenshot: "/fixtures/kitten-2-64-64.jpg", gif: true, hasUrl: true)),
            ("missing-image", item("image/jpeg")),
            ("pending-image", item("image/jpeg", size: 123_000, pending: true)),
            ("downloading-image", item("image/jpeg", size: 123_000, pending: true, downloaded: 20_300)),
            ("missing-video", item("video/mp4")),
            ("broken-image", item("image/jpeg", hasUrl: true)),
            // A video's url is its screenshot's (`getUrl`); the broken one has none.
            ("broken-video", item("video/mp4", hasUrl: false)),
            ("other-content-type", item("application/octet-stream")),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<12)
    func story(theme: String, index: Int) throws {
        let (name, a) = Self.stories[index]
        let tile = MediaGridItem(attachment: a)
        let side = tile.naturalSide
        try Snapshot.assertMatches(tile.frame(width: side, height: side).frame(width: 1168, alignment: .leading),
                                   story: "components-conversation-mediagallery-mediagriditem--\(name)", theme: theme)
    }
}

/// AttachmentSection.dom.stories.tsx: tiles from the capture (blurhash previews decoded from
/// the img src the capture recorded).
@MainActor
@Suite struct AttachmentSectionTests {
    static func tile(_ r: (String, String, Int)) -> MessageAttachment {
        let isGIF = r.1 == "GIF", isFixture = r.0.hasPrefix("/fixtures/")
        // A ready tile with a size shown is a video (its screenshot failed: the blurhash shows).
        let video = isGIF || (r.2 == 0 && !r.1.isEmpty)
        var a = MessageAttachment(contentType: video ? "video/mp4" : "image/png", fileName: nil,
                                  size: r.1.isEmpty || isGIF ? 1000 : MediaGalleryFixture.bytes(r.1), width: 400, height: 300)
        a.isGifFlag = isGIF
        a.hasUrl = r.2 == 0
        a.pending = r.2 == 2
        if isFixture { a.image = fixtureDataURLImage(r.0) } else { a.blurHash = fixtureDataURLImage(r.0) }
        return a
    }

    @Test(arguments: ["light", "dark"])
    func media(theme: String) throws {
        let view = AttachmentSection(header: "Today", kind: .media) {
            ForEach(Array(AttachmentSectionFixtures.media.enumerated()), id: \.offset) { _, r in MediaGridItem(attachment: Self.tile(r)) }
        }
        .frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-conversation-mediagallery-attachmentsection--media", theme: theme)
    }
}

/// Row builders shared by the list stories.
@MainActor
enum MediaGalleryRows {
    static func document(_ i: Int, _ r: (String, String, String, Int)) -> some View {
        DocumentListItem(attachment: MediaGalleryFixture.attachment(r.0, size: r.1, state: r.3),
                         message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.2)), authorTitle: "Alice")
    }
    static func audio(_ i: Int, _ r: (String, String, String, Int, [Double], Bool)) -> some View {
        let parts = r.1.components(separatedBy: " · ")
        let d = parts[2].split(separator: ":").compactMap { Double($0) }
        return AudioListItem(attachment: MediaGalleryFixture.attachment(r.0, contentType: "audio/mp3", size: parts[0], state: r.3),
                             message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.2)), authorTitle: "Alice",
                             isVoiceMessage: parts[1] == "Voice Message", duration: d.count == 2 ? d[0] * 60 + d[1] : 0,
                             peaks: r.3 == 0 ? r.4.map { $0 / 22 } : nil, isPlayed: !r.5)
    }
    static func link(_ i: Int, _ r: (String, String)) -> some View {
        var p = LinkPreview(url: "https://signal.org/", domain: "signal.org", title: "Signal", description: "description")
        if !r.1.isEmpty {
            var a = MessageAttachment(contentType: "image/png", fileName: nil, size: 1000, width: 400, height: 300)
            a.image = fixtureDataURLImage(r.1)
            p.image = a
        }
        return LinkPreviewItem(preview: p, message: MediaItemMessage(id: "\(i)", receivedAt: MediaGalleryFixture.date(r.0)), authorTitle: "Alice")
    }
}

@MainActor
@Suite struct AttachmentSectionListTests {
    @Test(arguments: ["light", "dark"])
    func lists(theme: String) throws {
        let c = "components-conversation-mediagallery-attachmentsection--"
        let docs = AttachmentSection(header: "Today", kind: .list) {
            ForEach(Array(AttachmentSectionListFixtures.documents.enumerated()), id: \.offset) { MediaGalleryRows.document($0.offset, $0.element) }
        }
        try Snapshot.assertMatches(TimelineMessageTests.stage(docs.frame(width: 1168)), story: c + "documents", theme: theme)
        let audio = AttachmentSection(header: "Today", kind: .list) {
            ForEach(Array(AttachmentSectionListFixtures.audio.enumerated()), id: \.offset) { MediaGalleryRows.audio($0.offset, $0.element) }
        }
        try Snapshot.assertMatches(TimelineMessageTests.stage(audio.frame(width: 1168)), story: c + "audio", theme: theme)
        let links = AttachmentSection(header: "Today", kind: .list) {
            ForEach(Array(AttachmentSectionListFixtures.links.enumerated()), id: \.offset) { MediaGalleryRows.link($0.offset, $0.element) }
        }
        try Snapshot.assertMatches(TimelineMessageTests.stage(links.frame(width: 1168)), story: c + "links", theme: theme)
    }
}

/// MediaGallery.dom.stories.tsx (the stories' Panel: ConversationPanel + PanelHeader). The Media
/// tab's sections come from the captures; each section's tiles get a date inside it (the
/// capture clock is 2026-11-04 12:00 London).
@MainActor
@Suite struct MediaGalleryTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_600)

    static func date(_ header: String) -> Date {
        switch header {
        case "Today": return now.addingTimeInterval(-3600)
        case "Yesterday": return now.addingTimeInterval(-86_400)
        case "This Week": return now.addingTimeInterval(-3 * 86_400)
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.timeZone = TimeZone(identifier: "Europe/London")
            f.dateFormat = "MMMM yyyy d"
            return f.date(from: "\(header) 15") ?? now
        }
    }

    static func items(_ story: String) -> [GalleryMediaItem] {
        var out: [GalleryMediaItem] = []
        for (header, tiles) in MediaGalleryFixtures.stories[story] ?? [] {
            for (i, t) in tiles.enumerated() {
                // Keep the capture's order within a section (newest first).
                let d = date(header).addingTimeInterval(-Double(i))
                out.append(GalleryMediaItem(id: "\(out.count)", kind: .media(AttachmentSectionTests.tile(t)),
                                            message: MediaItemMessage(id: "\(out.count)", receivedAt: d), authorTitle: "Alice"))
            }
        }
        return out
    }

    static func panel(_ items: [GalleryMediaItem]) -> some View {
        ConversationPanel(onBack: {}) {
            MediaGalleryPanelHeader(tab: .constant(.media), sortOrder: .constant(.date))
        } content: {
            MediaGallery(items: items, tab: .media)
        }
    }

    @Test(arguments: ["light", "dark"], ["empty", "no-media", "one-each", "populated", "no-documents"])
    func story(theme: String, name: String) throws {
        let id = "components-conversation-mediagallery-mediagallery--\(name)"
        let h = try Snapshot.referenceHeight(id, theme)
        let view = Self.panel(Self.items(name)).frame(width: 1200, height: h)
            .environment(\.conversationListNow, Self.now).environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
        try Snapshot.assertMatches(view, story: id, theme: theme)
    }
}
