// AudioSpecificConfig (ISO/IEC 14496-3 1.6.2.1, GASpecificConfig 4.4.1) and ADTS framing
// (13818-7 / 14496-3 1.A.2):
//
//   ASC  := audioObjectType:5 [== 31 → 32 + 6]  samplingFrequencyIndex:4 [== 15 → rate:24]
//           channelConfiguration:4  [AOT 5/29 (explicit SBR/PS) → extIndex:4 [rate:24] AOT:5]
//           GASpecificConfig := frameLengthFlag:1 dependsOnCoreCoder:1 [delay:14] extensionFlag:1
//           [syncExtensionType:11{0x2B7} extensionAOT:5 [== 5 → sbrPresentFlag:1 …]]
//   ADTS := syncword:12{0xFFF} ID:1 layer:2{0} protection_absent:1 profile:2 sf_index:4 private:1
//           channel_config:3 original:1 home:1 copyright_id:1 copyright_start:1 frame_length:13
//           buffer_fullness:11 raw_blocks:2 [crc:16] raw_data_block{raw_blocks+1}
//
// Supported: AAC-LC (object type 2) with 1024-sample frames, channel configurations 1–7.
// HE-AAC streams decode their AAC-LC core (at the core rate); SBR is not applied.

public import CodecCore

public struct AACConfig: Sendable, Equatable {
    public static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public var objectType: Int
    public var samplingIndex: Int
    public var sampleRate: Int
    public var channelConfiguration: Int
    /// Explicitly signalled SBR (HE-AAC): the core decodes at `sampleRate`, SBR would double it.
    public var sbrSignalled: Bool

    public var channels: Int { [0, 1, 2, 3, 4, 5, 6, 8][channelConfiguration] }

    public init(objectType: Int, samplingIndex: Int, channelConfiguration: Int, sbrSignalled: Bool = false) {
        self.objectType = objectType
        self.samplingIndex = samplingIndex
        self.sampleRate = samplingIndex < Self.sampleRates.count ? Self.sampleRates[samplingIndex] : 0
        self.channelConfiguration = channelConfiguration
        self.sbrSignalled = sbrSignalled
    }

    /// AudioSpecificConfig from an MP4 esds DecoderSpecificInfo.
    public static func parse(_ asc: ByteSlice) throws(ParseFailure) -> AACConfig {
        var r = MSBBitReader(asc.copyBytes(), policy: .fail)
        func objectType() throws(ParseFailure) -> Int {
            let t = Int(try r.bits(5, "ASC.audioObjectType"))
            return t == 31 ? 32 + Int(try r.bits(6, "ASC.audioObjectTypeExt")) : t
        }
        func frequency() throws(ParseFailure) -> (Int, Int?) {
            let i = Int(try r.bits(4, "ASC.samplingFrequencyIndex"))
            return i == 15 ? (15, Int(try r.bits(24, "ASC.samplingFrequency"))) : (i, nil)
        }
        var aot = try objectType()
        var (index, explicitRate) = try frequency()
        let channels = Int(try r.bits(4, "ASC.channelConfiguration"))
        var sbr = false
        if aot == 5 || aot == 29 {
            sbr = true
            _ = try frequency()            // the SBR output rate
            aot = try objectType()
        }
        guard aot == 2 else { throw ParseFailure(offset: 0, rule: "ASC.audioObjectType", reason: .invalid("object type \(aot) (only AAC-LC)")) }
        guard try r.bit("GASpecificConfig.frameLengthFlag") == 0 else {
            throw ParseFailure(offset: 0, rule: "GASpecificConfig.frameLengthFlag", reason: .invalid("960-sample frames"))
        }
        if try r.bit("GASpecificConfig.dependsOnCoreCoder") == 1 { _ = try r.bits(14, "GASpecificConfig.coreCoderDelay") }
        _ = try r.bit("GASpecificConfig.extensionFlag")
        // Backward-compatible SBR signalling (1.6.6.2.1): syncExtensionType:11{0x2B7}
        // extensionAudioObjectType:5 [== 5 → sbrPresentFlag:1 [extensionSamplingFrequencyIndex:4 …]]
        if !sbr, asc.count * 8 - r.bitPosition >= 16, r.peek(11) == 0x2B7 {
            try r.skip(11, "ASC.syncExtensionType")
            if try objectType() == 5, try r.bit("ASC.sbrPresentFlag") == 1 { sbr = true }
        }
        guard (1...7).contains(channels) else {
            throw ParseFailure(offset: 0, rule: "ASC.channelConfiguration", reason: .invalid("\(channels) (program config elements are not supported)"))
        }
        if let explicitRate {
            guard let i = sampleRates.firstIndex(of: explicitRate) else {
                throw ParseFailure(offset: 0, rule: "ASC.samplingFrequency", reason: .invalid("\(explicitRate) Hz"))
            }
            index = i
        }
        guard index < sampleRates.count else { throw ParseFailure(offset: 0, rule: "ASC.samplingFrequencyIndex", reason: .invalid("\(index)")) }
        return AACConfig(objectType: aot, samplingIndex: index, channelConfiguration: channels, sbrSignalled: sbr)
    }
}

public struct ADTSFrame: Sendable {
    public var config: AACConfig
    /// The raw_data_block(s) of the frame (CRC removed).
    public var payload: ByteSlice
    public var rawDataBlocks: Int
}

public enum ADTS {
    /// Splits an ADTS stream into frames; stops at the first byte that is not a frame header.
    public static func frames(_ bytes: [UInt8], maxFrames: Int = 1_000_000) throws(ParseFailure) -> [ADTSFrame] {
        var c = ByteCursor(bytes)
        var out: [ADTSFrame] = []
        // An ID3v2 tag may precede the stream.
        if let id3 = c.peek(10)?.copyBytes(), id3[0] == 0x49, id3[1] == 0x44, id3[2] == 0x33 {
            let size = (Int(id3[6] & 0x7F) << 21) | (Int(id3[7] & 0x7F) << 14) | (Int(id3[8] & 0x7F) << 7) | Int(id3[9] & 0x7F)
            try c.skip(10 + size, "ID3v2")
        }
        while c.remaining >= 7, out.count < maxFrames {
            let h = c.peek(7)!.copyBytes()
            guard h[0] == 0xFF, h[1] & 0xF6 == 0xF0 else {
                if out.isEmpty { throw c.fail("adts.syncword", .mismatch(expected: "0xFFF")) }
                break
            }
            var r = MSBBitReader(h, policy: .fail)
            _ = try r.bits(12, "adts.syncword")
            _ = try r.bit("adts.ID")
            _ = try r.bits(2, "adts.layer")
            let protectionAbsent = try r.bit("adts.protection_absent") == 1
            let profile = Int(try r.bits(2, "adts.profile"))
            let sf = Int(try r.bits(4, "adts.sampling_frequency_index"))
            _ = try r.bit("adts.private_bit")
            let channels = Int(try r.bits(3, "adts.channel_configuration"))
            _ = try r.bits(4, "adts.flags")
            let length = Int(try r.bits(13, "adts.frame_length"))
            _ = try r.bits(11, "adts.buffer_fullness")
            let blocks = Int(try r.bits(2, "adts.number_of_raw_data_blocks")) + 1
            let header = protectionAbsent ? 7 : 9
            guard profile == 1 else { throw c.fail("adts.profile", .invalid("profile \(profile) (only AAC-LC)")) }
            guard sf < AACConfig.sampleRates.count, (1...7).contains(channels), length >= header else {
                throw c.fail("adts.header", .invalid("sf \(sf), channels \(channels), length \(length)"))
            }
            guard length <= c.remaining else {
                // A truncated last frame is dropped.
                break
            }
            try c.skip(header, "adts.header")
            let payload = try c.bytes(length - header, "adts.raw_data_block")
            out.append(ADTSFrame(config: AACConfig(objectType: 2, samplingIndex: sf, channelConfiguration: channels), payload: payload, rawDataBlocks: blocks))
        }
        return out
    }
}
