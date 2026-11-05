// ImageGrid stories (ts/components/conversation/ImageGrid.dom.stories.tsx), from the stories'
// ImageGrid props (Fixtures/imagegrid-stories.json, evaluated from the story file). Fixture
// urls load from Signal-Desktop/fixtures; blurhashes are decoded here as the media service
// would; the default blurhash is light (the stories pass no theme).

import CodecCore
import Foundation
import Synchronization
import ImageJPEG
import ImagePNG
import ImageGIF
import ImageWebP
import SwiftUI
import Testing
@testable import SignalUI

/// Decoded fixtures by url (debug-build decoding of the large JPEGs is slow).
nonisolated let fixtureCache = Mutex<[String: RGBAImage?]>([:])

/// A Signal-Desktop fixture image by url path (`/fixtures/…`); nil for non-images.
func fixtureByURL(_ url: String?) -> RGBAImage? {
    guard let url, url.hasPrefix("/fixtures/") else { return nil }
    if let hit = fixtureCache.withLock({ $0[url] }) { return hit }
    let image = decodeFixture(url)
    fixtureCache.withLock { $0[url] = image }
    return image
}

private func decodeFixture(_ url: String) -> RGBAImage? {
    let name = String(url.dropFirst("/fixtures/".count))
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: file) else { return nil }
    let bytes = [UInt8](data)
    let lower = name.lowercased()
    if lower.hasSuffix(".png") { return (try? PNGDecoder.decode(bytes)).map { RGBAImage($0.stillImage) } }
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return (try? JPEGDecoder.decode(bytes)).map { RGBAImage($0) } }
    if lower.hasSuffix(".webp") { return (try? WebPDecoder.decode(bytes)).map { RGBAImage($0.stillImage) } }
    if lower.hasSuffix(".gif") { return (try? GIFDecoder.decode(bytes)).map { RGBAImage($0.stillImage) } }
    return nil
}

/// Frame `index` of an animated fixture GIF (Chromium animates GIFs in the captures).
func fixtureGIFFrame(_ name: String, _ index: Int) -> RGBAImage? {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: file), case .animated(let a, _)? = try? GIFDecoder.decode([UInt8](data)),
          a.frames.indices.contains(index) else { return nil }
    return RGBAImage(a.frames[index].image)
}

/// Fixtures/audio-waveforms.json by fixture url.
let audioWaveforms: [String: AudioWaveform] = {
    struct W: Decodable { var waveform: [Int]; var duration: Double }
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/audio-waveforms.json")
    let all = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: W].self, from: $0) } ?? [:]
    return all.mapValues { AudioWaveform(waveform: $0.waveform, duration: $0.duration) }
}()

/// A PNG from Tests/SignalUITests/Fixtures.
func fixturePNGFile(_ name: String) -> RGBAImage? {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    guard let data = try? Data(contentsOf: file), let png = try? PNGDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(png.stillImage)
}

/// A story's `AttachmentForUIType` (the fields the UI reads).
struct StoryAttachment: Decodable {
    struct Thumb: Decodable { var url: String? }
    var contentType: String?
    var fileName: String?
    var width: Int?
    var height: Int?
    var size: Int?
    var path: String?
    var url: String?
    var pending: Bool?
    var totalDownloaded: Int?
    var isPermanentlyUndownloadable: Bool?
    var wasTooBig: Bool?
    var incrementalMac: String?
    var chunkSize: Int?
    var blurHash: String?
    var caption: String?
    var screenshot: Thumb?
    var thumbnail: Thumb?
    var flags: Int?

    var model: MessageAttachment {
        var a = MessageAttachment(contentType: contentType ?? "", fileName: fileName, size: size ?? 0, width: width, height: height)
        a.isDownloaded = path != nil
        a.pending = pending ?? false
        a.totalDownloaded = totalDownloaded
        a.isPermanentlyUndownloadable = isPermanentlyUndownloadable ?? false
        a.wasTooBig = wasTooBig ?? false
        a.incremental = incrementalMac != nil && (chunkSize ?? 0) > 0
        a.caption = caption
        a.image = fixtureByURL(url)
        a.screenshot = fixtureByURL(screenshot?.url)
        a.hasThumbnail = thumbnail != nil
        a.thumbnailImage = fixtureByURL(thumbnail?.url)
        a.isGifFlag = ((flags ?? 0) & 8) != 0
        a.hasUrl = url != nil
        // The first frame of a video (what a paused GIF shows), extracted with ffmpeg.
        if url == "/fixtures/cat-gif.mp4" { a.videoFrame = fixturePNGFile("cat-gif-frame0.png") }
        // Audio: the waveform Signal Desktop computes (Tools/gen-audio-waveforms.py).
        if let url, a.isAudio { a.audioWaveform = audioWaveforms[url] }
        // react-blurhash decodes a GIF's hash at 32×32; Image's at about 32×32 in its aspect.
        a.blurHash = blurHash.flatMap {
            a.isGIF ? BlurHashImage.trustedSquare($0) : BlurHashImage.trusted($0, intrinsicWidth: width, intrinsicHeight: height)
        }
        return a
    }
}

@MainActor
@Suite struct ImageGridTests {
    struct GridProps: Decodable {
        var attachments: [StoryAttachment]
        var bottomOverlay: Bool?
        var direction: String?
        var isSticker: Bool?
        var stickerSize: Double?
        var withContentAbove: Bool?
        var withContentBelow: Bool?
    }

    static let stories: [(String, GridProps)] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/imagegrid-stories.json")
        let all = (try? JSONDecoder().decode([String: [GridProps]].self, from: Data(contentsOf: url))) ?? [:]
        return all.keys.sorted().compactMap { k in all[k]?.first.map { (k, $0) } }
    }()

    @Test func allStoriesLoaded() { #expect(Self.stories.count == 36) }

    @Test(arguments: ["light", "dark"], 0..<36)
    func story(theme: String, index: Int) throws {
        let (name, p) = Self.stories[index]
        let grid = ImageGrid(attachments: p.attachments.map(\.model), direction: p.direction == "outgoing" ? .outgoing : .incoming,
                             bottomOverlay: p.bottomOverlay ?? false, isSticker: p.isSticker ?? false,
                             stickerSize: (p.stickerSize ?? 0) > 0 ? CGFloat(p.stickerSize ?? 0) : nil,
                             withContentAbove: p.withContentAbove ?? false, withContentBelow: p.withContentBelow ?? false, blurHashDark: false,
                             showVisualAttachment: { _ in }, showMediaNoLongerAvailableToast: {}, cancelDownload: {}, startDownload: {})
        let id = "components-conversation-imagegrid--\(name)"
        try Snapshot.assertMatches(grid.frame(width: 1168, height: try Snapshot.referenceHeight(id, theme), alignment: .topLeading),
                                   story: id, theme: theme)
    }
}
