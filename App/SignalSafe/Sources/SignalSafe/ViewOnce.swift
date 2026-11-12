// View-once media (upstream `isTapToView`, Message `#handleOpen` and showLightboxForViewOnceMedia):
// the timeline shows only the tap-to-view row. Opening it reads and decodes the media into memory
// first (upstream copies the file to a temporary one), then erases the message everywhere
// (`Messenger.openViewOnce`: the attachments go, our other devices and the sender are told), and
// shows it in the Lightbox's view-once mode (no save, forward or browsing; videos loop). Closing
// drops it.

import AppKit
import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// The view-once media on screen, held in memory only.
struct ViewOnceViewer {
    let id = UUID()
    var messageId: String
    var image: RGBAImage?
    var player: VideoPlaybackEngine?
    var isGIF = false
    var authorTitle: String
    var authorColor: String
    var timestamp: Date
}

@MainActor extension SignalSession {
    /// `#handleOpen` for view-once media.
    func openTapToView(_ m: TimelineMessage) {
        if m.direction == .outgoing { return toast = .tapToViewExpiredOutgoing }
        if m.isViewed { return toast = .tapToViewExpiredIncoming }
        // Erased elsewhere, or broken: the row's "Learn more" is all there is.
        guard !m.isErased, let a = m.attachments.first?.attachment else { return }
        if !a.isDownloaded {
            if a.pending == true { cancelDownloads(m) } else { downloadAttachments(m) }
            return
        }
        guard viewOnceViewer == nil, let session = signalSession else { return }
        let store = session.attachmentStore, media = media
        let author = contactTitle(m.author), color = contactColor(m.author), sentAt = Date(milliseconds: m.sentAt)
        Task {
            var viewer = ViewOnceViewer(messageId: m.id, authorTitle: author, authorColor: color, timestamp: sentAt)
            if AttachmentPolicy.isVideo(a.contentType) {
                // The decode session holds the bytes: the file can go.
                guard let (player, _) = try? await makeVideoPlayer(a) else { return Self.trace("view-once: video failed") }
                viewer.player = player
                viewer.isGIF = (a.flags ?? 0) & 8 != 0
            } else {
                guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil,
                      let image = await Self.decodeForDisplay(bytes, media: media, maxDimension: Self.lightboxMaxDimension,
                                                              animated: Self.mayAnimate(a.contentType))
                else { return Self.trace("view-once: image failed") }
                viewer.image = image
            }
            do {
                try await session.messenger.openViewOnce(m.id)
            } catch {
                Self.trace("view-once: erase failed: \(error)")
                await viewer.player?.unload()
                return
            }
            viewOnceViewer = viewer
            if let player = viewer.player {
                player.isLooping = true
                await player.play()
            }
        }
    }

    func closeViewOnce() {
        if let player = viewOnceViewer?.player { Task { await player.unload() } }
        viewOnceViewer = nil
    }
}

/// The Lightbox in view-once mode.
struct ViewOnceLightbox: View {
    @Bindable var session: SignalSession
    let i18n: Localizer

    var body: some View {
        if let v = session.viewOnceViewer {
            let item = v.player != nil
                ? LightboxMediaItem(kind: .video, player: v.player, isGIF: v.isGIF)
                : LightboxMediaItem(kind: .image, image: v.image)
            Lightbox(media: [item], isViewOnce: true,
                     header: LightboxHeaderInfo(title: v.authorTitle, color: v.authorColor, timestamp: v.timestamp.formatted(date: .abbreviated, time: .shortened)),
                     closeLightbox: { session.closeViewOnce() })
        }
    }
}
