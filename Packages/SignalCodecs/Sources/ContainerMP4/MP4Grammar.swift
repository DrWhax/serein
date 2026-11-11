// ISO/IEC 14496-12 (ISOBMFF) and 14496-14/-15 (MP4, AVC file format) grammar: the boxes a
// progressive (non-fragmented) MP4 needs to be demuxed.
//
//   box        := size:u32be type:4 [size == 1 → largesize:u64be] [type == 'uuid' → usertype:16] body
//                 size == 0: to the end of the enclosing range (top level only); size ≥ header
//   file       := box*                              (ftyp first if present; one moov; mdat anywhere)
//   moov       := mvhd trak+ other*                 trak := tkhd edts? mdia other*
//   mdia       := mdhd hdlr minf                    minf := (vmhd|smhd|nmhd)? dinf? stbl
//   stbl       := stsd stts ctts? stss? stsc (stsz|stz2) (stco|co64) other*
//   full box   := version:u8 flags:u24 body         (mvhd/tkhd/mdhd/elst: version 1 = 64-bit times)
//   stsd       := full count:u32 sampleEntry{count}
//   avc1/avc3  := reserved:6 dataRefIndex:u16 pre_defined/reserved:16 width:u16 height:u16 …:50 avcC other*
//   mp4a       := reserved:6 dataRefIndex:u16 version:u16 …:6 channels:u16 sampleSize:u16 …:4 rate:u32(16.16) [v1: 16 | v2: 36] esds
//   avcC       := 1 profile compat level 0b111111·lengthSizeMinusOne:2 0b111·numSPS:5 (len:u16 sps){numSPS} numPPS:u8 (len:u16 pps){numPPS} ext*
//   hvc1/hev1  := (as avc1) hvcC other*
//   hvcC       := 1 profile_space:2 tier:1 profile_idc:5 compat:u32 constraints:48 level:u8 0b1111·min_spatial_seg:12
//                 0b111111·parallelismType:2 0b111111·chromaFormat:2 0b11111·bitDepthLumaMinus8:3 0b11111·bitDepthChromaMinus8:3
//                 avgFrameRate:u16 constantFrameRate:2 numTemporalLayers:3 temporalIdNested:1 lengthSizeMinusOne:2
//                 numOfArrays:u8 (completeness:1 0 nalType:6 numNalus:u16 (len:u16 nal){numNalus}){numOfArrays}   (14496-15 8.3.3.1)
//   esds       := full descriptor(ES 0x03 → DecoderConfig 0x04 → DecoderSpecificInfo 0x05); length = 1–4 bytes of 7 bits
//
// Every length is checked against the enclosing range before it is used; counts are bounded
// (MP4Limits) before anything is allocated; offsets are only ever compared against the file
// size, never dereferenced here.

public import CodecCore

public typealias FourCC = UInt32

extension FourCC {
    public init(_ s: String) {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = v << 8 | UInt32(c) }
        self = v
    }

    public var fourCCString: String {
        String(String.UnicodeScalarView([24, 16, 8, 0].map { Unicode.Scalar(UInt8(truncatingIfNeeded: self >> $0)) }))
    }
}

public struct MP4Limits: Sendable {
    public var maxDepth = 16
    public var maxBoxes = 200_000
    public var maxTracks = 64
    public var maxSamples = 4_000_000
    public var maxEditEntries = 1024
    public var maxTableEntries = 4_000_000
    public init() {}
}

public struct Box: Sendable {
    public var type: FourCC
    /// Offset of the box (its size field) in the file.
    public var offset: Int
    public var body: ByteSlice
}

enum BoxGrammar {
    /// The boxes of a range (a file or a container box's body).
    static func children(_ range: ByteSlice, topLevel: Bool, limits: MP4Limits, count: inout Int) throws(ParseFailure) -> [Box] {
        var c = range.cursor()
        var out: [Box] = []
        while !c.isAtEnd {
            let start = c.consumed
            guard c.remaining >= 8 else {
                // A few stray bytes after the last box are tolerated at top level (some writers pad).
                if topLevel { break }
                throw c.fail("box", .unexpectedEnd(needed: 8, available: c.remaining))
            }
            let size32 = try c.u32be("box.size")
            let type = try c.u32be("box.type")
            var header = 8
            var size: UInt64 = UInt64(size32)
            if size32 == 1 {
                size = try c.u64be("box.largesize")
                header = 16
            } else if size32 == 0 {
                guard topLevel else { throw c.fail("box.size", .invalid("size 0 inside a container")) }
                size = UInt64(c.remaining + header)
            }
            if type == FourCC("uuid") {
                _ = try c.bytes(16, "box.usertype")
                header += 16
            }
            guard size >= UInt64(header) else { throw c.fail("box.size", .invalid("size \(size) < header \(header)")) }
            let bodyLength = size - UInt64(header)
            guard bodyLength <= UInt64(c.remaining) else {
                // A truncated final mdat (an interrupted download) is still demuxable up to here.
                if topLevel, type == FourCC("mdat") {
                    // It is a box too: it counts against the budget like any other.
                    count += 1
                    guard count <= limits.maxBoxes else { throw c.fail("box", .limitExceeded("more than \(limits.maxBoxes) boxes")) }
                    out.append(Box(type: type, offset: range.lowerBound + start, body: c.rest()))
                    break
                }
                throw c.fail("box.size", .unexpectedEnd(needed: Int(clamping: bodyLength), available: c.remaining))
            }
            count += 1
            guard count <= limits.maxBoxes else { throw c.fail("box", .limitExceeded("more than \(limits.maxBoxes) boxes")) }
            out.append(Box(type: type, offset: range.lowerBound + start, body: try c.bytes(Int(bodyLength), "box.body")))
        }
        return out
    }

    static func fullBox(_ c: inout ByteCursor) throws(ParseFailure) -> (version: UInt8, flags: UInt32) {
        (try c.u8("fullbox.version"), try c.u24be("fullbox.flags"))
    }
}

// MARK: AST

public enum TrackKind: Sendable, Equatable {
    case video, audio
    case other(FourCC)
}

public struct EditEntry: Sendable, Equatable {
    /// In the movie timescale.
    public var segmentDuration: UInt64
    /// In the media timescale; -1 = an empty edit (a gap).
    public var mediaTime: Int64
    public var rate: Int32
}

public struct AVCDecoderConfiguration: Sendable, Equatable {
    public var profile: UInt8
    public var compatibility: UInt8
    public var level: UInt8
    /// 1, 2 or 4 (the NAL unit length prefix in samples).
    public var nalLengthSize: Int
    public var sequenceParameterSets: [ByteSlice]
    public var pictureParameterSets: [ByteSlice]
}

/// HEVCDecoderConfigurationRecord: the stream's profile and its VPS/SPS/PPS (and SEI) NAL units.
public struct HEVCDecoderConfiguration: Sendable, Equatable {
    public var profileSpace: Int
    public var tier: Int
    public var profileIdc: Int
    public var levelIdc: Int
    public var chromaFormat: Int
    public var bitDepthLuma: Int
    public var bitDepthChroma: Int
    /// 1, 2 or 4 (the NAL unit length prefix in samples).
    public var nalLengthSize: Int
    /// Parameter-set NAL units (with their 2-byte headers), in record order.
    public var videoParameterSets: [ByteSlice]
    public var sequenceParameterSets: [ByteSlice]
    public var pictureParameterSets: [ByteSlice]
}

public struct AACConfiguration: Sendable, Equatable {
    /// MPEG-4 objectTypeIndication (0x40 = MPEG-4 audio, 0x67 = MPEG-2 AAC LC, …).
    public var objectTypeIndication: UInt8
    /// AudioSpecificConfig (ISO/IEC 14496-3 1.6.2.1), for the AAC decoder.
    public var audioSpecificConfig: ByteSlice
    public var averageBitrate: UInt32
}

public enum SampleEntry: Sendable, Equatable {
    case avc(fourCC: FourCC, width: Int, height: Int, config: AVCDecoderConfiguration)
    case hevc(fourCC: FourCC, width: Int, height: Int, config: HEVCDecoderConfiguration)
    case aac(channels: Int, sampleRate: Int, config: AACConfiguration)
    case unsupported(FourCC)

    public var fourCC: FourCC {
        switch self {
        case .avc(let f, _, _, _): f
        case .hevc(let f, _, _, _): f
        case .aac: FourCC("mp4a")
        case .unsupported(let f): f
        }
    }
}

public struct MP4Sample: Sendable, Equatable {
    /// Absolute file offset of the sample's bytes.
    public var offset: Int
    public var size: Int
    /// Decode and composition times, in the track's media timescale.
    public var decodeTime: Int64
    public var compositionTime: Int64
    public var isSync: Bool
    /// 1-based index into the track's sample entries (stsd).
    public var descriptionIndex: Int
}

public struct MP4Track: Sendable, Equatable {
    public var id: UInt32
    public var kind: TrackKind
    public var timescale: UInt32
    /// Media duration (mdhd), in `timescale`.
    public var duration: UInt64
    /// tkhd's width/height (16.16 → integer pixels; the presentation size).
    public var presentationWidth: Int
    public var presentationHeight: Int
    /// Clockwise rotation from the tkhd matrix (0, 90, 180, 270).
    public var rotation: Int
    public var editList: [EditEntry]
    public var sampleEntries: [SampleEntry]
    public var samples: [MP4Sample]

    /// The media time the first edit starts at (B-frame or AAC priming delay); 0 without
    /// an edit list. Presentation time = compositionTime − this.
    public var presentationOffset: Int64 {
        editList.first(where: { $0.mediaTime >= 0 }).map(\.mediaTime) ?? 0
    }
}

public struct MP4File: Sendable, Equatable {
    public var majorBrand: FourCC?
    public var compatibleBrands: [FourCC]
    public var movieTimescale: UInt32
    /// mvhd duration, in `movieTimescale`.
    public var movieDuration: UInt64
    public var tracks: [MP4Track]
    /// Whether moov comes before the media data (progressive playback, "faststart").
    public var moovBeforeMdat: Bool

    public var durationSeconds: Double { movieTimescale == 0 ? 0 : Double(movieDuration) / Double(movieTimescale) }
    public var videoTracks: [MP4Track] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [MP4Track] { tracks.filter { $0.kind == .audio } }
}
