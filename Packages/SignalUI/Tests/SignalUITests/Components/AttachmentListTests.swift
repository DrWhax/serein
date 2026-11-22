// ts/components/conversation/AttachmentList.dom.stories.tsx, StagedGenericAttachment.dom.stories.tsx
// and StagedPlaceholderAttachment.dom.stories.tsx. (AttachmentList EmptyList renders nothing.)

import AppKit
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AttachmentListTests {
    /// `fakeDraftAttachment`: a path, no dimensions.
    static func draft(_ contentType: String, _ fileName: String, url: String?, screenshot: String? = nil) -> MessageAttachment {
        var a = MessageAttachment(contentType: contentType, fileName: fileName, size: 10304, width: nil, height: nil)
        a.isDownloaded = true
        a.hasUrl = url != nil
        a.image = fixtureByURL(url)
        a.screenshot = fixtureByURL(screenshot)
        return a
    }

    static let tina = draft("image/jpeg", "tina-rolf-269345-unsplash.jpg", url: "/fixtures/tina-rolf-269345-unsplash.jpg")
    static let video = draft("video/mp4", "pixabay-Soap-Bubble-7141.mp4", url: "/fixtures/kitten-4-112-112.jpg", screenshot: "/fixtures/kitten-4-112-112.jpg")
    /// The captures caught the animated GIF on its 9th frame.
    static var gif: MessageAttachment {
        var a = draft("image/gif", "giphy-GVNv0UpeYm17e", url: "/fixtures/giphy-GVNvOUpeYmI7e.gif")
        a.image = fixtureGIFFrame("giphy-GVNvOUpeYmI7e.gif", 8)
        return a
    }

    /// With no header, the rail's 12px top margin collapses out of the story's root div (the
    /// capture starts at the rail).
    static func list(_ a: [MessageAttachment]) -> some View {
        AttachmentList(attachments: a, onAddAttachment: {}, onClickAttachment: { _ in }, onCloseAttachment: { _ in }, onClose: {})
            .padding(.top, a.count > 1 ? 0 : -12)
    }

    @Test(arguments: ["light", "dark"])
    func attachmentList(theme: String) throws {
        let c = "components-conversation-attachmentlist--"
        try Snapshot.assertMatches(Self.list([Self.tina]), story: c + "one-file", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina]), story: c + "staged-image-missing-dimensions", theme: theme)
        // The image fails to load: the tile stays with no picture.
        try Snapshot.assertMatches(Self.list([Self.draft("image/jpeg", "tina-rolf-269345-unsplash.jpg", url: "/fixtures/this-image-does-not-exist.jpg")]),
                                   story: c + "staged-image-that-fails-to-load", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina, Self.video, Self.gif]), story: c + "multiple-visual-attachments", theme: theme)
        try Snapshot.assertMatches(Self.list([Self.tina, Self.draft("text/plain", "lorem-ipsum.txt", url: "/fixtures/lorem-ipsum.txt"),
                                              Self.draft("audio/mp3", "incompetech-com-Agnus-Dei-X.mp3", url: "/fixtures/incompetech-com-Agnus-Dei-X.mp3"),
                                              Self.video, Self.gif]),
                                   story: c + "multiple-with-non-visual-types", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func staged(theme: String) throws {
        func generic(_ name: String) -> some View {
            StagedGenericAttachment(attachment: MessageAttachment(contentType: "text/plain", fileName: name, size: 14243, width: nil, height: nil))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        let c = "components-conversation-stagedgenericattachment--"
        try Snapshot.assertMatches(generic("manifesto.txt"), story: c + "text-file", theme: theme)
        try Snapshot.assertMatches(generic("this-is-my-very-important-manifesto-you-must-read-it.txt"), story: c + "long-name", theme: theme)
        try Snapshot.assertMatches(generic("manifesto.reallylongtxt"), story: c + "long-extension", theme: theme)
        try Snapshot.assertMatches(StagedPlaceholderAttachment {}.frame(maxWidth: .infinity, alignment: .leading),
                                   story: "components-conversation-stagedplaceholderattachment--default", theme: theme)
    }
}

@MainActor @Suite(.serialized) struct AttachmentRemovalTests {
    @Observable fileprivate final class Draft {
        var attachments: [MessageAttachment] = [255, 0].map { value in
            var attachment = MessageAttachment(contentType: "image/png", fileName: "\(value).png", size: 4, width: 120, height: 120)
            attachment.image = RGBAImage(width: 1, height: 1, pixels: Data([UInt8(value), UInt8(value), UInt8(value), 255]))
            attachment.isDownloaded = true
            attachment.hasUrl = true
            return attachment
        }
        var opened = false
    }

    private struct Composer: View {
        let draft: Draft
        var body: some View {
            AttachmentList(attachments: draft.attachments, canEditImages: true,
                           onClickAttachment: { _ in draft.opened = true },
                           onCloseAttachment: { draft.attachments.remove(at: $0) })
                .frame(width: 320, height: 160, alignment: .topLeading)
        }
    }

    /// Upstream's close button (16 pt, 4 pt in from the tile's top-right corner) removes only
    /// its own image, without opening the image editor.
    @Test func closeButtonRemovesOnlyItsImage() async throws {
        let draft = Draft()
        let host = NSHostingView(rootView: Composer(draft: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        // The first 120 pt tile spans x 12…132 and y 23…143 from the top: its button's centre
        // is 12 pt in from that corner (window coordinates count y from the bottom).
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: 160 - 35),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        #expect(draft.attachments.map(\.fileName) == ["0.png"])
        #expect(!draft.opened)
    }
}
