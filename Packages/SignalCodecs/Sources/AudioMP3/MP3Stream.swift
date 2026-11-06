// MPEG-1/2/2.5 Layer III framing (ISO/IEC 11172-3 2.4.1.3, 13818-3) and the encoder tags
// that precede the audio (Xing/Info + LAME, VBRI):
//
//   stream   := ID3v2? (garbage | frame)* ID3v1? APEv2?
//   header   := sync:11{0x7FF} version:2{≠01} layer:2{01 = III} protection_absent:1
//               bitrate_index:4{1…14} sampling_frequency:2{≠11} padding:1 private:1
//               mode:2 mode_extension:2 copyright:1 original:1 emphasis:2 (not checked, as FFmpeg)
//   frame    := header [crc:16] side_info main_data      size = 144000·kbps/Hz (MPEG-1) or
//                                                         72000·kbps/Hz (MPEG-2/2.5) + padding
//   Xing     := ("Xing" | "Info") flags:u32 [frames:u32] [bytes:u32] [toc:100] [quality:u32]
//               LAME := "LAME" version:5 … delay:12 padding:12 (at Xing + 120 + 21)
//   VBRI     := at header + 36: "VBRI" version:u16 delay:u16 quality:u16 bytes:u32 frames:u32 …
//
// Free-format (bitrate index 0) and Layers I/II are refused. A frame is accepted when the next
// one follows it with the same version, layer and rate (or the stream ends); anything else is
// skipped byte by byte, so junk between frames cannot desynchronise the decoder.

public import CodecCore

public struct MP3Header: Sendable, Equatable {
    public enum Version: Sendable, Equatable { case mpeg1, mpeg2, mpeg25 }
    public enum Mode: Int, Sendable, Equatable { case stereo = 0, jointStereo = 1, dualChannel = 2, mono = 3 }

    public var version: Version
    public var hasCRC: Bool
    public var bitrateKbps: Int
    /// 0…8 across versions: 44100, 48000, 32000, 22050, 24000, 16000, 11025, 12000, 8000 Hz.
    public var sampleRateIndex: Int
    public var padding: Bool
    public var mode: Mode
    public var modeExtension: Int

    public static let sampleRates = [44100, 48000, 32000, 22050, 24000, 16000, 11025, 12000, 8000]
    static let bitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let bitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    public var sampleRate: Int { Self.sampleRates[sampleRateIndex] }
    public var channels: Int { mode == .mono ? 1 : 2 }
    /// Low sampling frequencies (MPEG-2 and 2.5): one granule per frame.
    public var lsf: Bool { version != .mpeg1 }
    public var samplesPerFrame: Int { lsf ? 576 : 1152 }
    public var frameLength: Int { (lsf ? 72_000 : 144_000) * bitrateKbps / sampleRate + (padding ? 1 : 0) }
    public var sideInfoLength: Int { lsf ? (channels == 1 ? 9 : 17) : (channels == 1 ? 17 : 32) }

    /// Parses a 4-byte header; nil when it is not a Layer III header we decode.
    public static func parse(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> MP3Header? {
        guard b0 == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }
        let versionBits = (b1 >> 3) & 3, layerBits = (b1 >> 1) & 3
        guard versionBits != 1, layerBits == 1 else { return nil }
        let version: Version = versionBits == 3 ? .mpeg1 : versionBits == 2 ? .mpeg2 : .mpeg25
        let bitrateIndex = Int(b2 >> 4), rateBits = Int((b2 >> 2) & 3)
        guard bitrateIndex != 0, bitrateIndex != 15, rateBits != 3 else { return nil }
        let rateIndex = rateBits + (version == .mpeg1 ? 0 : version == .mpeg2 ? 3 : 6)
        return MP3Header(version: version, hasCRC: b1 & 1 == 0,
                         bitrateKbps: (version == .mpeg1 ? bitratesV1 : bitratesV2)[bitrateIndex],
                         sampleRateIndex: rateIndex, padding: (b2 >> 1) & 1 == 1,
                         mode: Mode(rawValue: Int(b3 >> 6))!, modeExtension: Int((b3 >> 4) & 3))
    }

    /// Frames of one stream share version and rate; the channel mode may change (the decoder
    /// follows it).
    func sameStream(as other: MP3Header) -> Bool {
        version == other.version && sampleRateIndex == other.sampleRateIndex
    }
}

public struct MP3Frame: Sendable {
    public var header: MP3Header
    /// The whole frame, header included.
    /// The frame, header included; shorter than `header.frameLength` only for a stream's
    /// truncated last frame (its missing bytes decode as zeros).
    public var bytes: ByteSlice
    public var offset: Int
}

/// The encoder's tag in the first frame (Xing/Info with LAME's extension, or VBRI).
public struct MP3EncoderInfo: Sendable, Equatable {
    public var frameCount: Int?
    public var byteCount: Int?
    /// Samples the encoder added at the start / end (LAME tag, VBRI delay); the decoder adds
    /// `MP3Decoder.decoderDelay` more at the start.
    public var encoderDelay: Int?
    public var encoderPadding: Int?
    public var isCBR: Bool
    public var encoder: String?
}

public struct MP3Stream: Sendable {
    public var frames: [MP3Frame]
    public var info: MP3EncoderInfo?

    public var sampleRate: Int { frames.first?.header.sampleRate ?? 0 }
    /// The first frame's channel count (later frames may differ; see `MP3Decoder.decode(_:channels:)`).
    public var channels: Int { frames.first?.header.channels ?? 0 }
    public var samplesPerFrame: Int { frames.first?.header.samplesPerFrame ?? 0 }

    /// Duration after removing the encoder and decoder delay and the padding (as players and
    /// upstream's `<audio>` report it), in seconds.
    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        var samples = (info?.frameCount ?? frames.count) * samplesPerFrame
        if let d = info?.encoderDelay, let p = info?.encoderPadding { samples = max(0, samples - d - p) }
        return Double(samples) / Double(sampleRate)
    }

    public static func parse(_ data: [UInt8], maxFrames: Int = 2_000_000) throws(ParseFailure) -> MP3Stream {
        var start = 0, end = data.count
        // ID3v2 (possibly several, possibly with a footer).
        while end - start >= 10, data[start] == 0x49, data[start + 1] == 0x44, data[start + 2] == 0x33,
              data[start + 6] | data[start + 7] | data[start + 8] | data[start + 9] < 0x80 {
            let size = Int(data[start + 6]) << 21 | Int(data[start + 7]) << 14 | Int(data[start + 8]) << 7 | Int(data[start + 9])
            let footer = data[start + 5] & 0x10 != 0 ? 10 : 0
            start = min(end, start + 10 + size + footer)
        }
        // ID3v1 and APEv2 at the end.
        if end - start >= 128, data[end - 128] == 0x54, data[end - 127] == 0x41, data[end - 126] == 0x47 { end -= 128 }
        if end - start >= 32, Array(data[end - 32 ..< end - 24]) == Array("APETAGEX".utf8) {
            let size = Int(data[end - 20]) | Int(data[end - 19]) << 8 | Int(data[end - 18]) << 16 | Int(data[end - 17]) << 24
            let flags = data[end - 9]
            let total = size + (flags & 0x80 != 0 ? 32 : 0)
            if total <= end - start { end -= total }
        }

        func header(at p: Int) -> MP3Header? {
            guard p + 4 <= end else { return nil }
            return MP3Header.parse(data[p], data[p + 1], data[p + 2], data[p + 3])
        }
        var frames: [MP3Frame] = []
        let all = ByteSlice(data)
        var p = start
        var first: MP3Header?
        while p + 4 <= end, frames.count < maxFrames {
            guard let h = header(at: p), first.map({ h.sameStream(as: $0) }) ?? true else { p += 1; continue }
            let len = h.frameLength
            guard len >= 4 + (h.hasCRC ? 2 : 0) + h.sideInfoLength else { p += 1; continue }
            if p + len > end {
                // A cut-short last frame is kept when its side information is complete.
                if frames.isEmpty { p += 1; continue }
                if end - p >= 4 + (h.hasCRC ? 2 : 0) + h.sideInfoLength {
                    frames.append(MP3Frame(header: h, bytes: try slice(all, p, end - p), offset: p))
                }
                break
            }
            // Until the stream is locked, a frame counts only when its successor confirms it
            // (or it ends the data exactly); once locked, junk after a frame is skipped later.
            let confirmed = p + len + 4 > end || header(at: p + len).map { $0.sameStream(as: h) } == true
            if frames.isEmpty && !confirmed { p += 1; continue }
            if first == nil { first = h }
            frames.append(MP3Frame(header: h, bytes: try slice(all, p, len), offset: p))
            p += len
        }
        guard !frames.isEmpty else {
            throw ParseFailure(offset: start, rule: "mp3.frame", reason: .mismatch(expected: "a Layer III frame header"))
        }
        var stream = MP3Stream(frames: frames, info: nil)
        if let info = encoderInfo(frames[0]) {
            stream.info = info
            stream.frames.removeFirst()     // the tag frame carries no audio
        }
        return stream
    }

    /// CRC-16/ARC (reflected 0x8005), as LAME's tag uses.
    static func crc16(_ data: [UInt8], _ crc: UInt16 = 0) -> UInt16 {
        var c = crc
        for byte in data {
            c ^= UInt16(byte)
            for _ in 0 ..< 8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        }
        return c
    }

    static func slice(_ all: ByteSlice, _ offset: Int, _ length: Int) throws(ParseFailure) -> ByteSlice {
        var c = all.cursor()
        try c.skip(offset, "mp3.frame")
        return try c.bytes(length, "mp3.frame")
    }

    /// Xing/Info (+ LAME) or VBRI in a frame.
    static func encoderInfo(_ frame: MP3Frame) -> MP3EncoderInfo? {
        let b = frame.bytes.copyBytes()
        let h = frame.header
        func u32(_ i: Int) -> Int? {
            guard i + 4 <= b.count else { return nil }
            return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        func tag(_ i: Int, _ s: String) -> Bool { i + 4 <= b.count && Array(b[i ..< i + 4]) == Array(s.utf8) }
        let x = 4 + (h.hasCRC ? 2 : 0) + h.sideInfoLength
        if tag(x, "Xing") || tag(x, "Info"), let flags = u32(x + 4) {
            var info = MP3EncoderInfo(isCBR: tag(x, "Info"))
            var i = x + 8
            if flags & 1 != 0 { info.frameCount = u32(i); i += 4 }
            if flags & 2 != 0 { info.byteCount = u32(i); i += 4 }
            if flags & 4 != 0 { i += 100 }
            if flags & 8 != 0 { i += 4 }
            if i + 24 <= b.count, b[i ..< i + 4].allSatisfy({ (0x20...0x7E).contains($0) }) {
                info.encoder = String(decoding: b[i ..< i + 9].filter { (0x20...0x7E).contains($0) }, as: UTF8.self)
                // The delay fields are read for LAME and FFmpeg tags, and for any tag whose
                // CRC verifies (CRC-16 of every frame byte before the CRC field at i + 34; 190
                // bytes in LAME's stereo MPEG-1 layout).
                let crcOK = i + 36 <= b.count
                    && MP3Stream.crc16(Array(b.prefix(i + 34))) == UInt16(b[i + 34]) << 8 | UInt16(b[i + 35])
                if tag(i, "LAME") || tag(i, "Lavc") || tag(i, "Lavf") || crcOK {
                    info.encoderDelay = Int(b[i + 21]) << 4 | Int(b[i + 22]) >> 4
                    info.encoderPadding = Int(b[i + 22] & 0x0F) << 8 | Int(b[i + 23])
                }
            }
            return info
        }
        if tag(36, "VBRI"), b.count >= 36 + 26 {
            var info = MP3EncoderInfo(isCBR: false)
            info.encoderDelay = Int(b[42]) << 8 | Int(b[43])
            info.byteCount = u32(46)
            info.frameCount = u32(50)
            info.encoder = "VBRI"
            return info
        }
        return nil
    }
}
