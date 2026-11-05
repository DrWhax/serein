// Stories of AttachmentDetailPill, AttachmentStatusIcon, FileThumbnail, ImageOrBlurhash and
// GroupDescription, from their evaluated story props (Fixtures/<component>-stories.json).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

func storyFixture<T: Decodable>(_ file: String, _ type: T.Type) -> [(String, T)] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(file)")
    let all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [T]].self, from: $0) } ?? [:]
    return all.keys.sorted().compactMap { k in all[k]?.first.map { (k, $0) } }
}

@MainActor
@Suite struct AttachmentPartsTests {
    struct PillProps: Decodable { var attachments: [StoryAttachment]; var isGif: Bool? }
    struct StatusProps: Decodable { var attachment: StoryAttachment; var isIncoming: Bool? }
    struct ThumbProps: Decodable { var fileName: String? }
    struct BlurProps: Decodable { var src: String?; var blurHash: String? }
    struct DescriptionProps: Decodable { var title: String; var text: String }

    /// The three "-blank" pill stories render nothing (all downloaded / no attachments).
    static let pills = storyFixture("attachmentdetailpill-stories.json", PillProps.self).filter { !$0.0.hasSuffix("-blank") }

    @Test(arguments: ["light", "dark"], 0..<8)
    func attachmentDetailPill(theme: String, index: Int) throws {
        let (name, p) = Self.pills[index]
        let view = AttachmentDetailPill(attachments: p.attachments.map(\.model), isGif: p.isGif ?? false, startDownload: {}, cancelDownload: {})
        try Snapshot.assertMatches(view, story: "components-conversation-attachmentdetailpill--\(name)", theme: theme)
    }

    /// "interactive" (its start / stop harness buttons above the icon) has its own test.
    static let statusIcons = storyFixture("attachmentstatusicon-stories.json", StatusProps.self).filter { $0.0 != "interactive" }

    /// `Interactive`: two preflight-reset <button>s (plain inline text) on the gray div, then
    /// the not-yet-downloaded icon (its 2px block margins inside the div).
    @Test(arguments: ["light", "dark"])
    func attachmentStatusIconInteractive(theme: String) throws {
        let p = storyFixture("attachmentstatusicon-stories.json", StatusProps.self).first { $0.0 == "interactive" }!.1
        let view = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                CSSText("start download", type: .bodyLarge, wrap: .nowrap, color: .labelPrimary)
                CSSText("stop download", type: .bodyLarge, wrap: .nowrap, color: .labelPrimary)
            }
            AttachmentStatusIcon(attachment: p.attachment.model, isIncoming: p.isIncoming ?? false) { EmptyView() }
        }
        .frame(width: 1168, alignment: .leading)
        .background(RGBA(hex: 0x808080).color)
        try Snapshot.assertMatches(view, story: "components-conversation-attachmentstatusicon--interactive", theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<3)
    func attachmentStatusIcon(theme: String, index: Int) throws {
        let (name, p) = Self.statusIcons[index]
        // Its 2px block margins sit outside the captured box.
        let view = AttachmentStatusIcon(attachment: p.attachment.model, isIncoming: p.isIncoming ?? false) { EmptyView() }
            .padding(.vertical, -2)
            .frame(width: 1168, alignment: .leading)
            .background(RGBA(hex: 0x808080).color)      // the stories' <div style={{ backgroundColor: 'gray' }}>
        try Snapshot.assertMatches(view, story: "components-conversation-attachmentstatusicon--\(name)", theme: theme)
    }

    static let thumbnails = storyFixture("filethumbnail-stories.json", ThumbProps.self)

    @Test(arguments: ["light", "dark"], 0..<5)
    func fileThumbnail(theme: String, index: Int) throws {
        let (name, p) = Self.thumbnails[index]
        let view = FileThumbnail(contentType: "application/octet-stream", fileName: p.fileName).frame(width: 1168, alignment: .leading)
        try Snapshot.assertMatches(view, story: "components-filethumbnail--\(name)", theme: theme)
    }

    static let blurs = storyFixture("imageorblurhash-stories.json", BlurProps.self)

    @Test(arguments: ["light", "dark"], 0..<6)
    func imageOrBlurhash(theme: String, index: Int) throws {
        let (name, p) = Self.blurs[index]
        // style width/height 100%: the story's 1168px block, square (the image's or the
        // 32×32 blurhash's aspect).
        let view = ImageOrBlurhash(image: fixtureByURL(p.src),
                                   blurHash: p.blurHash.flatMap { BlurHashImage.trusted($0, intrinsicWidth: nil, intrinsicHeight: nil) })
            .frame(width: 1168, height: 1168)
        try Snapshot.assertMatches(view, story: "components-imageorblurhash--\(name)", theme: theme)
    }

    static let descriptions = storyFixture("groupdescription-stories.json", DescriptionProps.self)

    @Test(arguments: ["light", "dark"], 0..<7)
    func groupDescription(theme: String, index: Int) throws {
        let (name, p) = Self.descriptions[index]
        let view = GroupDescription(title: p.title, text: p.text, onReadMore: {}).frame(width: 1168, alignment: .leading)
        try Snapshot.assertMatches(view, story: "components-conversation-groupdescription--\(name)", theme: theme)
    }

    @Test func fixturesLoaded() {
        #expect(Self.pills.count == 8 && Self.statusIcons.count == 3 && Self.thumbnails.count == 5 && Self.blurs.count == 6 && Self.descriptions.count == 7)
    }
}
