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
        let id = UUID()
        var messageId: String
        var attachments: [SignalCore.MessageAttachment]
        var index: Int
        /// The sender's name (nil: ours, shown as "You").
        var authorTitle: String?
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
        guard let path = visual[index].path, mediaIsAvailable(path: path, messageId: m.id) else { return }
        let author = m.direction == .outgoing ? nil : contactTitle(m.author)
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
        guard let l = lightbox, signalSession != nil else { return }
        let a = l.attachments[index]
        guard a.isDownloaded else { return }
        if AttachmentPolicy.isImage(a.contentType) {
            _ = largeImage(for: a, of: l.messageId)
            return
        }
        guard l.players[index] == nil else { Task { await l.players[index]?.play() }; return }
        let messageId = l.messageId
        let instance = l.id
        if inlineVideo?.messageId == messageId { inlineVideo?.player.pause() }
        Task {
            do {
                guard let (player, info) = try await makeVideoPlayer(a) else { return }
                guard lightbox?.id == instance, lightbox?.index == index, lightbox?.players[index] == nil,
                      let path = a.path, mediaIsAvailable(path: path, messageId: messageId) else { await player.unload(); return }
                lightbox?.players[index] = player
                lightbox?.durations[index] = info.duration
                Self.trace("video: playing \(info.width)x\(info.height), \(info.duration)s, audio \(info.hasAudio)")
                await player.play()
            } catch {
                Self.trace("video failed: \(error)")
            }
        }
    }

    /// A video's player: a decode session in the media service (our Swift H.264/HEVC decoders),
    /// plus its audio (MP3/AAC decoded there too) when it has a track.
    func makeVideoPlayer(_ a: SignalCore.MessageAttachment) async throws -> (VideoPlaybackEngine, VideoInfo)? {
        guard let session = signalSession else { return nil }
        let store = session.attachmentStore, media = media
        guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil else { return nil }
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
        return (player, info)
    }

    /// A lone video played in its bubble (one at a time): started, or resumed if it is the one.
    func playVideoInline(_ m: TimelineMessage) {
        guard let a = m.attachments.first?.attachment, AttachmentPolicy.isVideo(a.contentType), a.isDownloaded else { return }
        guard let path = a.path, mediaIsAvailable(path: path, messageId: m.id) else { return }
        if let current = inlineVideo, current.messageId == m.id {
            Task { await current.player.play() }
            return
        }
        stopInlineVideo()
        stopAudio()
        let id = m.id
        let generation = inlineVideoGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let (player, _) = try await makeVideoPlayer(a) else { return }
                guard generation == inlineVideoGeneration, let path = a.path, mediaIsAvailable(path: path, messageId: id) else {
                    await player.unload()
                    return
                }
                inlineVideo = (id, player, path)
                player.onEnded = { [weak self] in Task { @MainActor in
                    guard let self, self.inlineVideoGeneration == generation else { return }
                    self.stopInlineVideo()
                } }
                await player.play()
            } catch {
                Self.trace("inline video failed: \(error)")
            }
        }
    }

    func stopInlineVideo() {
        inlineVideoGeneration &+= 1
        guard let current = inlineVideo else { return }
        inlineVideo = nil
        Task { await current.player.unload() }
    }

    /// "Save": the plaintext with the quarantine properties, where the user picks.
    func saveLightboxItem() {
        guard let l = lightbox, let session = signalSession else { return }
        let a = l.attachments[l.index]
        let name = Self.suggestedFilename(a, sentAt: Int64(l.timestamp.timeIntervalSince1970 * 1000), index: l.index + 1)
        if Self.isFileDangerous(name) { return toast = .dangerousFileType }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let db = clientDatabase else { return }
            try MediaAvailability.export(a, of: l.messageId, to: url, database: db, store: session.attachmentStore)
            toast = .fileSaved(fullPath: url.path, countOfFiles: 1)
        } catch {
            Self.trace("save failed: \(error)")
            toast = .error
        }
    }

    /// The Lightbox's larger decode (cached apart from the timeline's), for the message it shows.
    func largeImage(for a: SignalCore.MessageAttachment, of messageId: String? = nil) -> RGBAImage? {
        guard let path = a.path, a.isDownloaded else { return nil }
        let key = "large:" + path
        if let hit = images[key] { return hit }
        return loadImage(key: key, path: path, messageId: messageId, maxDimension: Self.lightboxMaxDimension,
                         animated: Self.mayAnimate(a.contentType)) { store in try store.plaintext(of: a) }
    }

    /// A video's poster frame (the screenshot stored at download).
    func posterImage(for a: SignalCore.MessageAttachment) -> RGBAImage? {
        guard let s = a.screenshot else { return nil }
        let key = "poster:" + s.path
        if let hit = images[key] { return hit }
        let file = LocalFile(path: s.path, localKey: s.localKey, size: s.size)
        return loadImage(key: key, path: s.path, maxDimension: Self.displayMaxDimension) { store in try store.plaintext(of: file) }
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
                return LightboxMediaItem(kind: .image, image: session.largeImage(for: a, of: l.messageId) ?? session.image(for: a))
            }
            Lightbox(media: items, selectedIndex: l.index,
                     header: LightboxHeaderInfo(title: l.authorTitle ?? i18n("icu:you"), color: l.authorColor,
                                                timestamp: l.timestamp.formatted(date: .abbreviated, time: .shortened)),
                     closeLightbox: { session.closeLightbox() }, onForward: { session.closeLightbox(); session.forward([l.messageId]) },
                     onSave: { session.saveLightboxItem() },
                     onPrevAttachment: { session.selectLightbox(l.index - 1) }, onNextAttachment: { session.selectLightbox(l.index + 1) },
                     onSelectAttachment: { session.selectLightbox($0) })
        }
    }
}
