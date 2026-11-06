// Port of ts/components/StoryImage.dom.tsx (+ StoryImage.scss): a story's media — its text
// attachment, the image (cover-fitted; the thumbnail in 46×72 thumbnails), a video frame, or
// while it is not downloaded / pending / failed the dark default blurhash at the attachment's
// size, with a spinner bubble or the "Can't download story" message (an alert in thumbnails).

import SignalI18n
import SwiftUI

/// The parts of a story's `AttachmentType` StoryImage shows.
public struct StoryAttachmentData: Sendable, Hashable {
    public var contentType: String
    public var image: RGBAImage?
    public var thumbnail: RGBAImage?
    public var textAttachment: TextAttachmentData?
    public var width: Int?
    public var height: Int?
    /// Decoded by the media service (`blurHash`); nil uses the dark default.
    public var blurHash: RGBAImage?
    /// Not downloaded yet (no local file).
    public var isNotResolved: Bool
    public var pending: Bool
    public var error: Bool

    public init(contentType: String = "image/jpeg", image: RGBAImage? = nil, thumbnail: RGBAImage? = nil, textAttachment: TextAttachmentData? = nil,
                width: Int? = 800, height: Int? = 600, blurHash: RGBAImage? = nil, isNotResolved: Bool = false, pending: Bool = false, error: Bool = false) {
        self.contentType = contentType
        self.image = image
        self.thumbnail = thumbnail
        self.textAttachment = textAttachment
        self.width = width
        self.height = height
        self.blurHash = blurHash
        self.isNotResolved = isNotResolved
        self.pending = pending
        self.error = error
    }
}

public struct StoryImage<Children: View>: View {
    let attachment: StoryAttachmentData?
    let firstName: String
    let isMe: Bool
    let isThumbnail: Bool
    /// The viewer contains the picture in the window (`.StoryViewer__story img { object-fit: contain }`).
    let fitContain: Bool
    let videoSource: (any CallVideoFrameSource)?
    let children: Children
    @Environment(\.i18n) var i18n

    public init(attachment: StoryAttachmentData?, firstName: String, isMe: Bool = false, isThumbnail: Bool = false, fitContain: Bool = false,
                videoSource: (any CallVideoFrameSource)? = nil, @ViewBuilder children: () -> Children) {
        self.fitContain = fitContain
        self.attachment = attachment
        self.firstName = firstName
        self.isMe = isMe
        self.isThumbnail = isThumbnail
        self.videoSource = videoSource
        self.children = children()
    }

    /// The image could not be shown (`hasImgError`): it failed to decode or there is none.
    var hasError: Bool { attachment.map { $0.error || (!$0.isNotResolved && !$0.pending && $0.textAttachment == nil && $0.image == nil && videoSource == nil) } ?? false }

    @ViewBuilder func content(_ a: StoryAttachmentData) -> some View {
        let isPending = a.pending && a.textAttachment == nil && !hasError
        if let text = a.textAttachment {
            TextAttachment(textAttachment: text, isThumbnail: isThumbnail)
        } else if a.isNotResolved || isPending || hasError {
            // <Blurhash width height>: the attachment's size, centred and clipped.
            let image = a.blurHash ?? BlurHashImage.trusted(BlurHashImage.defaultHash(dark: true), intrinsicWidth: a.width, intrinsicHeight: a.height)
            if let image { PixelImage(image, fit: .fill).frame(width: CGFloat(a.width ?? 800), height: CGFloat(a.height ?? 600)) }
        } else if !isThumbnail, a.contentType.hasPrefix("video/") {
            // <video>: its frames, nothing until it plays (the image is only its screenshot).
            if let videoSource { RemoteVideoStack(source: videoSource, fit: fitContain ? .contain : .cover) }
        } else if let image = (isThumbnail ? a.thumbnail ?? a.image : a.image) {
            PixelImage(image, fit: fitContain ? .contain : .cover)
        }
    }

    @ViewBuilder func overlay(_ a: StoryAttachmentData) -> some View {
        if a.pending && a.textAttachment == nil && !hasError {
            Spinner(svgSize: .small, ariaLabel: i18n("icu:loading"))
                .frame(width: 24, height: 24)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(rgba: LegacyColor.gray75)))
        } else if hasError {
            if isThumbnail {
                SignalIcon("alert-outline", size: 32, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white), mask: true).frame(width: 32, height: 32)
            } else {
                CSSText(isMe ? i18n("icu:StoryImage__error--you") : i18n("icu:StoryImage__error2", ["name": .string(firstName)]),
                        style: LegacyType.body1(), color: .labelPrimary)
            }
        }
    }

    public var body: some View {
        if let attachment {
            ZStack {
                Color.clear
                content(attachment)
                overlay(attachment)
                children
            }
            .frame(width: isThumbnail ? 46 : nil, height: isThumbnail ? 72 : nil)
            .clipped()
        }
    }
}

extension StoryImage where Children == EmptyView {
    public init(attachment: StoryAttachmentData?, firstName: String, isMe: Bool = false, isThumbnail: Bool = false, fitContain: Bool = false,
                videoSource: (any CallVideoFrameSource)? = nil) {
        self.init(attachment: attachment, firstName: firstName, isMe: isMe, isThumbnail: isThumbnail, fitContain: fitContain, videoSource: videoSource) {
            EmptyView()
        }
    }
}
