// What the main process may ask the media decoder service. Requests carry plaintext bytes
// only (attachment keys never leave the main process); results are flat values that the
// caller re-validates (`validated()`) before use.

import Foundation

public enum MediaProcessingError: Error, Equatable, Sendable {
    case unsupportedFormat
    case undecodable(String)
    case invalidResult
}

/// An image's still frame, as metadata.
public struct ImageInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 4×3 blurhash of the image scaled into 200×200 (`imageToBlurHash`).
    public var blurHash: String
    public var isAnimated: Bool

    public init(width: Int, height: Int, blurHash: String, isAnimated: Bool) {
        self.width = width
        self.height = height
        self.blurHash = blurHash
        self.isAnimated = isAnimated
    }

    /// Bounds an untrusted result: positive dimensions within 16384, a well-formed 4×3 hash.
    public func validated() throws -> ImageInfo {
        guard (1...16384).contains(width), (1...16384).contains(height), blurHash.count == 28,
              blurHash.unicodeScalars.allSatisfy({ $0.isASCII }) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// A PNG thumbnail (`makeImageThumbnail`: cover-scaled to `size`×`size`, centre-cropped).
public struct Thumbnail: Codable, Equatable, Sendable {
    public var png: Data
    public var width: Int
    public var height: Int
    public var contentType: String { "image/png" }

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }

    public func validated(size: Int) throws -> Thumbnail {
        guard width == size, height == size, png.count >= 8, png.count <= 4 << 20,
              png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// An image's first frame for display (EXIF orientation applied), scaled to fit within
/// `maxDimension` — pixels only, so the app never parses an image format itself.
public struct DisplayImage: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// RGBA8, straight alpha, width × height × 4 bytes.
    public var rgba: Data
    /// The decoded image's size before scaling.
    public var originalWidth: Int
    public var originalHeight: Int
    public init(width: Int, height: Int, rgba: Data, originalWidth: Int, originalHeight: Int) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }
    public func validated(maxDimension: Int) throws -> DisplayImage {
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height), (1...16384).contains(originalWidth),
              (1...16384).contains(originalHeight), rgba.count == width * height * 4 else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// `displayAnimation`'s result: an image as the timeline's `<img>` shows it. An animation (GIF,
/// APNG, animated WebP) has every frame, fully composited and fitted within `maxDimension`; a
/// still image has one frame.
public struct DisplayAnimation: Codable, Equatable, Sendable {
    /// Most bytes an animation's frames take together. A longer animation is scaled down further.
    public static let maxBytes = 48 << 20
    /// Most frames. An animation with more is shown still (its first frame).
    public static let maxFrames = 1024
    /// Longest frame duration as encoded (APNG: 65535 s).
    public static let maxDelay = 65_535_000
    public var width: Int
    public var height: Int
    /// The frames' pixels one after another: RGBA8, straight alpha, width × height × 4 bytes each.
    public var frames: Data
    /// Each frame's duration in milliseconds as encoded (the player applies Chromium's clamp).
    public var delays: [Int]
    /// How many times the animation plays (0: forever), as Chromium counts it for the format.
    public var plays: Int
    /// The decoded image's size before scaling.
    public var originalWidth: Int
    public var originalHeight: Int

    public init(width: Int, height: Int, frames: Data, delays: [Int], plays: Int, originalWidth: Int, originalHeight: Int) {
        self.width = width
        self.height = height
        self.frames = frames
        self.delays = delays
        self.plays = plays
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }

    public var frameCount: Int { delays.count }

    public func validated(maxDimension: Int) throws -> DisplayAnimation {
        // Sizes are bounded before they are multiplied: 4096 × 4096 × 4 × 1024 fits an Int.
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height), maxDimension <= 4096,
              (1...16384).contains(originalWidth), (1...16384).contains(originalHeight), (1...Self.maxFrames).contains(delays.count),
              frames.count == width * height * 4 * delays.count, delays.count == 1 || frames.count <= Self.maxBytes,
              delays.allSatisfy({ (0...Self.maxDelay).contains($0) }), (0...Int(UInt32.max)).contains(plays)
        else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// `MediaQualityLevels` (ts/util/scaleImageToLevel.preload.ts).
public enum MediaQualityLevel: Int, Codable, Sendable, CaseIterable {
    case one = 1, two = 2, three = 3

    public struct Data: Equatable, Sendable {
        public var maxDimensions: Int
        /// JPEG quality, 0…100 (canvas 0.7 → 70).
        public var quality: Int
        public var size: Int
        public var thresholdSize: Int
    }

    public var data: Data {
        let mib = 1024 * 1024
        switch self {
        case .one: return Data(maxDimensions: 1600, quality: 70, size: mib, thresholdSize: mib / 5)
        case .two: return Data(maxDimensions: 2048, quality: 75, size: mib * 3 / 2, thresholdSize: mib * 3 / 10)
        case .three: return Data(maxDimensions: 4096, quality: 75, size: mib * 3, thresholdSize: mib * 2 / 5)
        }
    }

    public static let scalableDimensions = [3072, 2048, 1600, 1024, 768]
    public static let minDimensions = 512
}

/// An image re-encoded for sending (EXIF and other metadata dropped by the re-encode).
public struct ScaledImage: Codable, Equatable, Sendable {
    public var data: Foundation.Data
    public var contentType: String
    public var width: Int
    public var height: Int

    public init(data: Foundation.Data, contentType: String, width: Int, height: Int) {
        self.data = data
        self.contentType = contentType
        self.width = width
        self.height = height
    }

    public func validated(maxDimension: Int) throws -> ScaledImage {
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height), !data.isEmpty,
              ["image/jpeg", "image/png"].contains(contentType) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// A HEIC / HEIF photo re-encoded as a full-size JPEG for sending (upstream heicConverterWorker:
/// heic-convert to JPEG at quality 0.75, alpha dropped, before autoScale).
public struct ConvertedImage: Codable, Equatable, Sendable {
    public static let quality = 75
    public var data: Foundation.Data
    public var width: Int
    public var height: Int

    public init(data: Foundation.Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }

    /// A JPEG (SOI … EOI) of plausible size and dimensions.
    public func validated() throws -> ConvertedImage {
        guard (1...16384).contains(width), (1...16384).contains(height), data.count >= 4, data.count <= 256 << 20,
              data.prefix(2) == Foundation.Data([0xFF, 0xD8]), data.suffix(2) == Foundation.Data([0xFF, 0xD9]) else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// What a link-preview page says about itself (`parseMetadata`): raw strings, bounded.
public struct LinkPreviewHTML: Codable, Equatable, Sendable {
    public static let maxLength = 4096
    /// `MAX_HTML_BYTES_TO_LOAD` (1000 KiB): the most of a page that is parsed.
    public static let maxInputBytes = 1000 * 1024
    public var title: String
    public var description: String?
    /// As written in the page; resolve against the page's final URL.
    public var imageHref: String?
    /// `og:modified_time` & co. as written (`Date.parse` input).
    public var rawDate: String?

    public init(title: String, description: String?, imageHref: String?, rawDate: String?) {
        self.title = title
        self.description = description
        self.imageHref = imageHref
        self.rawDate = rawDate
    }

    /// Re-checked in the main process: a title, and nothing over the limit.
    public func validated() throws -> LinkPreviewHTML {
        guard !title.isEmpty, title.count <= Self.maxLength, (description?.count ?? 0) <= Self.maxLength,
              (imageHref?.count ?? 0) <= Self.maxLength, (rawDate?.count ?? 0) <= Self.maxLength else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// A sticker for the sticker creator (`processImage`): a 512px WebP of a still image (contained,
/// centred on transparency), or an animated PNG as given; or why it can't be one.
public struct StickerImage: Codable, Equatable, Sendable {
    public static let size = 512
    public static let minSize = 10
    public static let maxBytes = 300 * 1024

    /// The `StickerCreator--Toasts--…` reason a file was refused.
    public enum Refusal: String, Codable, Sendable {
        case errorProcessing = "StickerCreator--Toasts--errorProcessing"
        case tooLarge = "StickerCreator--Toasts--tooLarge"
        case notSquare = "StickerCreator--Toasts--APNG--notSquare"
        case dimensionsTooSmall = "StickerCreator--Toasts--APNG--dimensionsTooSmall"
        case dimensionsTooLarge = "StickerCreator--Toasts--APNG--dimensionsTooLarge"
        case animated = "StickerCreator--Toasts--animated"
    }

    public var data: Foundation.Data
    public var contentType: String
    public var refusal: Refusal?
    /// The sticker's pixels (RGBA8, previewWidth × previewHeight) for the creator to show.
    public var previewWidth: Int
    public var previewHeight: Int
    public var previewRGBA: Foundation.Data

    public init(data: Foundation.Data, contentType: String, refusal: Refusal? = nil, previewWidth: Int = 0, previewHeight: Int = 0,
                previewRGBA: Foundation.Data = Foundation.Data()) {
        self.data = data
        self.contentType = contentType
        self.refusal = refusal
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.previewRGBA = previewRGBA
    }

    public func validated() throws -> StickerImage {
        if refusal != nil { return StickerImage(data: Foundation.Data(), contentType: "", refusal: refusal) }
        guard !data.isEmpty, data.count <= Self.maxBytes, ["image/webp", "image/png"].contains(contentType),
              (1...Self.size).contains(previewWidth), (1...Self.size).contains(previewHeight),
              previewRGBA.count == previewWidth * previewHeight * 4 else { throw MediaProcessingError.invalidResult }
        return self
    }
}

/// The media decoder service.
public protocol MediaProcessing: Sendable {
    /// The sticker creator's conversion of a dropped image.
    func stickerImage(_ bytes: Data) async throws -> StickerImage
    func imageInfo(_ bytes: Data) async throws -> ImageInfo
    func thumbnail(_ bytes: Data, size: Int) async throws -> Thumbnail
    /// The first frame, fitted within `maxDimension` (1…4096), as RGBA for the timeline.
    func displayImage(_ bytes: Data, maxDimension: Int) async throws -> DisplayImage
    /// Every frame of an animated image, fitted within `maxDimension` (1…4096) and within
    /// `DisplayAnimation.maxBytes`; a still image's one frame.
    func displayAnimation(_ bytes: Data, maxDimension: Int) async throws -> DisplayAnimation
    /// `scaleImageToLevel`. Callers skip GIFs and non-images (`canBeTranscoded`).
    func scaleForSending(_ bytes: Data, contentType: String, level: MediaQualityLevel) async throws -> ScaledImage
    /// The sending side's HEIC conversion (handleImageAttachment → heicConverterWorker). The
    /// only request that decodes HEVC images: received HEIC is never displayed (upstream shows
    /// it as a file), so display / thumbnail / info refuse it.
    func convertHEIC(_ bytes: Data) async throws -> ConvertedImage
    /// The file without its metadata (Exif / XMP / IPTC / comments in images, user data and
    /// times in videos); throws when it cannot be parsed or its type has no stripper.
    func stripMetadata(_ bytes: Data, contentType: String) async throws -> Data

    // Audio (MP3; AAC in ADTS or MP4/M4A).
    /// Duration, format and the upstream waveform (`computeWaveform`).
    func audioSummary(_ bytes: Data) async throws -> AudioSummary
    /// Decoded samples [startFrame, startFrame + maxFrames) of the presentation timeline.
    func decodeAudio(_ bytes: Data, startFrame: Int, maxFrames: Int) async throws -> AudioChunk

    // Voice notes: upstream's recorder (MP3, LAME VBR 7, ≤ 90 kbps, mono) in the service.
    func startVoiceNote(sampleRate: Int) async throws -> UUID
    /// Mono float32 samples in [−1, 1].
    func appendVoiceNote(_ session: UUID, samples: [Float]) async throws
    func finishVoiceNote(_ session: UUID) async throws -> VoiceNote
    func cancelVoiceNote(_ session: UUID) async

    // Video (H.264 in MP4).
    func videoInfo(_ bytes: Data) async throws -> VideoInfo
    /// The first frame as displayed (rotated), PNG.
    func posterFrame(_ bytes: Data) async throws -> VideoPoster
    func openVideo(_ bytes: Data) async throws -> (session: UUID, info: VideoInfo)
    /// The next frames in display order (at most VideoLimits.maxFramesPerRequest); empty at the end.
    func videoFrames(_ session: UUID, count: Int) async throws -> [VideoFrame]
    /// Continues from the sync sample at or before `seconds` (the caller drops earlier frames).
    func seekVideo(_ session: UUID, to seconds: Double) async throws
    func closeVideo(_ session: UUID) async
}

extension Data {
    /// A stripped file is never larger than the original plus the 34-byte orientation-only
    /// Exif block a JPEG may get.
    public func validatedStripped(original: Data) throws -> Data {
        guard !isEmpty, count <= original.count + 64 else { throw MediaProcessingError.invalidResult }
        return self
    }
}

public enum MediaConstants {
    /// `THUMBNAIL_SIZE` (ts/util/captureDimensionsAndScreenshot.dom.ts)
    public static let thumbnailSize = 150
    public static let blurHashMaxDimension = 200
}
