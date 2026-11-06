// Opening a message's photos and videos (upstream Lightbox via showLightbox): images decoded
// larger by the media service, videos played from a media-service decode session (frames as
// validated YUV planes) with their AAC audio decoded the same way. Nothing here parses media.

import AppKit
import Foundation
import MediaXPCInterface
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

/// A media-service video session as the player's frame source.
struct XPCVideoSource: VideoFrameSource {
    let media: MediaXPCClient
    let session: UUID

    func frames(_ count: Int) async throws -> [VideoPlanes] {
        try await media.videoFrames(session, count: count).map {
            VideoPlanes(width: $0.width, height: $0.height, y: [UInt8]($0.y), u: [UInt8]($0.u), v: [UInt8]($0.v), fullRange: $0.fullRange,
                        matrix: $0.matrix, time: $0.time, transfer: $0.transfer, bitDepth: $0.bitDepth)
        }
    }

    func seek(to seconds: Double) async throws { try await media.seekVideo(session, to: seconds) }
    func close() async { await media.closeVideo(session) }
}

extension SignalSession {
    /// What the Lightbox shows: one message's visual attachments.
    struct LightboxState {
        var messageId: String
        var attachments: [SignalCore.MessageAttachment]
        var index: Int
        var authorTitle: String
        var authorColor: String
        var timestamp: Date
        var players: [Int: VideoPlaybackEngine] = [:]
        var durations: [Int: Double] = [:]
    }
}

@MainActor extension SignalSession {
    static let lightboxMaxDimension = 4096

    func openLightbox(_ m: TimelineMessage, index: Int) {
        let visual = m.attachments.map(\.attachment).filter { AttachmentPolicy.isImage($0.contentType) || AttachmentPolicy.isVideo($0.contentType) }
        guard visual.indices.contains(index) else { return }
        let author = m.direction == .outgoing ? "You" : contactTitle(m.author)
        lightbox = LightboxState(messageId: m.id, attachments: visual, index: index, authorTitle: author,
                                 authorColor: m.direction == .outgoing ? "A200" : contactColor(m.author), timestamp: Date(milliseconds: m.sentAt))
        prepareLightboxItem(index)
    }

    func selectLightbox(_ index: Int) {
        guard var l = lightbox, l.attachments.indices.contains(index) else { return }
        if let p = l.players[l.index] { p.pause() }
        l.index = index
        lightbox = l
        prepareLightboxItem(index)
    }

    func closeLightbox() {
        if let players = lightbox?.players.values { for p in players { Task { await p.unload() } } }
        lightbox = nil
    }

    /// Images: a large decode. Videos: a decode session plus audio, then play.
    func prepareLightboxItem(_ index: Int) {
        guard let l = lightbox, let session = signalSession else { return }
        let a = l.attachments[index]
        guard a.isDownloaded else { return }
        if AttachmentPolicy.isImage(a.contentType) {
            _ = largeImage(for: a)
            return
        }
        guard l.players[index] == nil else { Task { await l.players[index]?.play() }; return }
        let store = session.attachmentStore, media = media, messageId = l.messageId
        Task {
            guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil else { return }
            do {
                let (videoSession, info) = try await media.openVideo(bytes)
                var audio: AudioPlaybackEngine?
                if info.hasAudio {
                    let engine = AudioPlaybackEngine()
                    try? await engine.load({ start, count in
                        let chunk = try await media.decodeAudio(bytes, startFrame: start, maxFrames: count)
                        return PCMChunk(sampleRate: chunk.sampleRate, channels: chunk.channels, totalFrames: chunk.totalFrames,
                                        startFrame: chunk.startFrame, samples: chunk.floats)
                    })
                    audio = engine
                }
                let player = VideoPlaybackEngine(audio: audio)
                player.isLooping = (a.flags ?? 0) & 8 != 0
                await player.load(XPCVideoSource(media: media, session: videoSession), duration: info.duration, rotation: info.rotation)
                guard lightbox?.messageId == messageId else { await player.unload(); return }
                lightbox?.players[index] = player
                lightbox?.durations[index] = info.duration
                Self.trace("video: playing \(info.width)x\(info.height), \(info.duration)s, audio \(info.hasAudio)")
                await player.play()
            } catch {
                Self.trace("video failed: \(error)")
            }
        }
    }

    /// "Save": the plaintext with the quarantine properties, where the user picks.
    func saveLightboxItem() {
        guard let l = lightbox, let session = signalSession else { return }
        let a = l.attachments[l.index]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.fileName ?? "signal-\(Int(l.timestamp.timeIntervalSince1970))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? session.attachmentStore.export(a, to: url)
    }

    /// The Lightbox's larger decode (cached apart from the timeline's).
    func largeImage(for a: SignalCore.MessageAttachment) -> RGBAImage? {
        guard let path = a.path, a.isDownloaded else { return nil }
        let key = "large:" + path
        if let hit = images[key] { return hit }
        return loadImage(key: key, maxDimension: Self.lightboxMaxDimension) { store in try store.plaintext(of: a) }
    }

    /// A video's poster frame (the screenshot stored at download).
    func posterImage(for a: SignalCore.MessageAttachment) -> RGBAImage? {
        guard let s = a.screenshot else { return nil }
        let key = "poster:" + s.path
        if let hit = images[key] { return hit }
        let file = LocalFile(path: s.path, localKey: s.localKey, size: s.size)
        return loadImage(key: key, maxDimension: Self.displayMaxDimension) { store in try store.plaintext(of: file) }
    }
}

struct MediaLightbox: View {
    @Bindable var session: SignalSession
    let i18n: Localizer

    var body: some View {
        if let l = session.lightbox {
            let items = l.attachments.enumerated().map { i, a -> LightboxMediaItem in
                if AttachmentPolicy.isVideo(a.contentType) {
                    var item = LightboxMediaItem(kind: .video, thumbnail: session.posterImage(for: a), player: l.players[i],
                                                 isGIF: (a.flags ?? 0) & 8 != 0)
                    item.duration = l.durations[i] ?? a.duration
                    return item
                }
                return LightboxMediaItem(kind: .image, image: session.largeImage(for: a) ?? session.image(for: a))
            }
            Lightbox(media: items, selectedIndex: l.index,
                     header: LightboxHeaderInfo(title: l.authorTitle, color: l.authorColor,
                                                timestamp: l.timestamp.formatted(date: .abbreviated, time: .shortened)),
                     closeLightbox: { session.closeLightbox() }, onSave: { session.saveLightboxItem() },
                     onPrevAttachment: { session.selectLightbox(l.index - 1) }, onNextAttachment: { session.selectLightbox(l.index + 1) },
                     onSelectAttachment: { session.selectLightbox($0) })
        }
    }
}
