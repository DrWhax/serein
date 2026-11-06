// Turns the box tree into tracks with flat sample tables (ISO/IEC 14496-12 8.6–8.7):
//   stts → decode times, ctts → composition offsets, stsc + stco/co64 → chunk offsets,
//   stsz/stz2 → sizes, stss → sync samples (absent: every sample is a sync sample).
// All arithmetic is checked; every sample must lie inside the file.

public import CodecCore

public enum MP4Demuxer {
    static func t(_ s: String) -> FourCC { FourCC(s) }

    public static func parse(_ bytes: [UInt8], limits: MP4Limits = MP4Limits()) throws(ParseFailure) -> MP4File {
        try parse(ByteSlice(bytes), limits: limits)
    }

    public static func parse(_ file: ByteSlice, limits: MP4Limits = MP4Limits()) throws(ParseFailure) -> MP4File {
        var count = 0
        let top = try BoxGrammar.children(file, topLevel: true, limits: limits, count: &count)
        guard let moovIndex = top.firstIndex(where: { $0.type == t("moov") }) else {
            throw ParseFailure(offset: 0, rule: "file", reason: .mismatch(expected: "a moov box"))
        }
        guard top.filter({ $0.type == t("moov") }).count == 1 else {
            throw ParseFailure(offset: top[moovIndex].offset, rule: "file", reason: .invalid("more than one moov"))
        }
        if top.contains(where: { $0.type == t("moof") }) {
            throw ParseFailure(offset: 0, rule: "file", reason: .invalid("fragmented MP4 is not supported"))
        }
        var majorBrand: FourCC? = nil
        var compatible: [FourCC] = []
        if let ftyp = top.first(where: { $0.type == t("ftyp") }) {
            var c = ftyp.body.cursor()
            majorBrand = try c.u32be("ftyp.major")
            _ = try c.u32be("ftyp.minor")
            while c.remaining >= 4 { compatible.append(try c.u32be("ftyp.compatible")) }
        }
        let mdatIndex = top.firstIndex { $0.type == t("mdat") }
        let moov = top[moovIndex]
        let moovChildren = try BoxGrammar.children(moov.body, topLevel: false, limits: limits, count: &count)
        guard let mvhd = moovChildren.first(where: { $0.type == t("mvhd") }) else {
            throw ParseFailure(offset: moov.offset, rule: "moov", reason: .mismatch(expected: "mvhd"))
        }
        let (movieTimescale, movieDuration) = try parseMvhd(mvhd)
        let traks = moovChildren.filter { $0.type == t("trak") }
        guard traks.count <= limits.maxTracks else { throw ParseFailure(offset: moov.offset, rule: "moov", reason: .limitExceeded("tracks")) }
        var tracks: [MP4Track] = []
        var totalSamples = 0
        for trak in traks {
            let track = try parseTrak(trak, fileSize: file.upperBound, limits: limits, count: &count, totalSamples: &totalSamples)
            tracks.append(track)
        }
        return MP4File(majorBrand: majorBrand, compatibleBrands: compatible, movieTimescale: movieTimescale, movieDuration: movieDuration, tracks: tracks,
                       moovBeforeMdat: mdatIndex.map { moovIndex < $0 } ?? true)
    }

    static func child(_ boxes: [Box], _ type: String, in parent: Box) throws(ParseFailure) -> Box {
        guard let b = boxes.first(where: { $0.type == t(type) }) else {
            throw ParseFailure(offset: parent.offset, rule: parent.type.fourCCString, reason: .mismatch(expected: type))
        }
        return b
    }

    static func parseMvhd(_ b: Box) throws(ParseFailure) -> (UInt32, UInt64) {
        var c = b.body.cursor()
        let (version, _) = try BoxGrammar.fullBox(&c)
        if version == 1 {
            try c.skip(16, "mvhd.times")
            return (try c.u32be("mvhd.timescale"), try c.u64be("mvhd.duration"))
        }
        try c.skip(8, "mvhd.times")
        let timescale = try c.u32be("mvhd.timescale")
        let d = try c.u32be("mvhd.duration")
        return (timescale, d == 0xFFFF_FFFF ? 0 : UInt64(d))
    }

    static func parseTrak(_ trak: Box, fileSize: Int, limits: MP4Limits, count: inout Int, totalSamples: inout Int) throws(ParseFailure) -> MP4Track {
        let kids = try BoxGrammar.children(trak.body, topLevel: false, limits: limits, count: &count)
        let tkhd = try child(kids, "tkhd", in: trak)
        var c = tkhd.body.cursor()
        let (tv, _) = try BoxGrammar.fullBox(&c)
        try c.skip(tv == 1 ? 16 : 8, "tkhd.times")
        let trackId = try c.u32be("tkhd.track_ID")
        try c.skip(4 + (tv == 1 ? 8 : 4) + 8 + 2 + 2 + 2 + 2, "tkhd.reserved")
        var m: [Int32] = []
        for _ in 0..<9 { m.append(Int32(bitPattern: try c.u32be("tkhd.matrix"))) }
        let width = Int(try c.u32be("tkhd.width") >> 16), height = Int(try c.u32be("tkhd.height") >> 16)
        let rotation = rotationDegrees(a: m[0], b: m[1], c: m[3], d: m[4])

        var edits: [EditEntry] = []
        if let edts = kids.first(where: { $0.type == t("edts") }),
           let elst = try BoxGrammar.children(edts.body, topLevel: false, limits: limits, count: &count).first(where: { $0.type == t("elst") }) {
            var e = elst.body.cursor()
            let (ev, _) = try BoxGrammar.fullBox(&e)
            let n = Int(try e.u32be("elst.entry_count"))
            guard n <= limits.maxEditEntries, n * (ev == 1 ? 20 : 12) <= e.remaining else { throw e.fail("elst", .limitExceeded("edit entries")) }
            for _ in 0..<n {
                let d = ev == 1 ? try e.u64be("elst.segment_duration") : UInt64(try e.u32be("elst.segment_duration"))
                let mt = ev == 1 ? Int64(bitPattern: try e.u64be("elst.media_time")) : Int64(Int32(bitPattern: try e.u32be("elst.media_time")))
                let rate = Int32(bitPattern: try e.u32be("elst.media_rate"))
                edits.append(EditEntry(segmentDuration: d, mediaTime: mt, rate: rate))
            }
        }

        let mdia = try child(kids, "mdia", in: trak)
        let mdiaKids = try BoxGrammar.children(mdia.body, topLevel: false, limits: limits, count: &count)
        let mdhd = try child(mdiaKids, "mdhd", in: mdia)
        var h = mdhd.body.cursor()
        let (hv, _) = try BoxGrammar.fullBox(&h)
        try h.skip(hv == 1 ? 16 : 8, "mdhd.times")
        let timescale = try h.u32be("mdhd.timescale")
        let duration = hv == 1 ? try h.u64be("mdhd.duration") : UInt64(try h.u32be("mdhd.duration"))
        guard timescale > 0 else { throw h.fail("mdhd.timescale", .invalid("0")) }
        let hdlr = try child(mdiaKids, "hdlr", in: mdia)
        var hc = hdlr.body.cursor()
        _ = try BoxGrammar.fullBox(&hc)
        _ = try hc.u32be("hdlr.pre_defined")
        let handler = try hc.u32be("hdlr.handler_type")
        let kind: TrackKind = handler == t("vide") ? .video : handler == t("soun") ? .audio : .other(handler)

        let minf = try child(mdiaKids, "minf", in: mdia)
        let stbl = try child(try BoxGrammar.children(minf.body, topLevel: false, limits: limits, count: &count), "stbl", in: minf)
        let st = try BoxGrammar.children(stbl.body, topLevel: false, limits: limits, count: &count)
        let entries = try parseStsd(try child(st, "stsd", in: stbl), limits: limits, count: &count)
        let samples = try sampleTable(st, stbl: stbl, fileSize: fileSize, limits: limits, totalSamples: &totalSamples)
        guard samples.allSatisfy({ $0.descriptionIndex >= 1 && $0.descriptionIndex <= entries.count }) else {
            throw ParseFailure(offset: stbl.offset, rule: "stsc", reason: .invalid("sample description index out of range"))
        }
        return MP4Track(id: trackId, kind: kind, timescale: timescale, duration: duration, presentationWidth: width, presentationHeight: height,
                        rotation: rotation, editList: edits, sampleEntries: entries, samples: samples)
    }

    /// The display matrix's rotation (fixed-point 16.16, ISO/IEC 14496-12 6.2.2): only the
    /// four right-angle rotations are recognised; anything else counts as 0.
    static func rotationDegrees(a: Int32, b: Int32, c: Int32, d: Int32) -> Int {
        let one: Int32 = 0x10000
        switch (a, b, c, d) {
        case (0, one, -one, 0): return 90
        case (-one, 0, 0, -one): return 180
        case (0, -one, one, 0): return 270
        default: return 0
        }
    }

    // MARK: sample descriptions

    static func parseStsd(_ stsd: Box, limits: MP4Limits, count: inout Int) throws(ParseFailure) -> [SampleEntry] {
        var c = stsd.body.cursor()
        _ = try BoxGrammar.fullBox(&c)
        let n = Int(try c.u32be("stsd.entry_count"))
        let boxes = try BoxGrammar.children(c.rest(), topLevel: false, limits: limits, count: &count)
        guard n >= 1, boxes.count == n else { throw ParseFailure(offset: stsd.offset, rule: "stsd", reason: .invalid("\(n) entries, \(boxes.count) boxes")) }
        var out: [SampleEntry] = []
        for b in boxes {
            switch b.type {
            case t("avc1"), t("avc3"): out.append(try parseAVCEntry(b, limits: limits, count: &count))
            case t("mp4a"): out.append(try parseMP4AEntry(b, limits: limits, count: &count))
            default: out.append(.unsupported(b.type))
            }
        }
        return out
    }

    static func parseAVCEntry(_ b: Box, limits: MP4Limits, count: inout Int) throws(ParseFailure) -> SampleEntry {
        var c = b.body.cursor()
        try c.skip(6 + 2 + 16, "VisualSampleEntry.reserved")
        let width = Int(try c.u16be("VisualSampleEntry.width")), height = Int(try c.u16be("VisualSampleEntry.height"))
        try c.skip(4 + 4 + 4 + 2 + 32 + 2 + 2, "VisualSampleEntry.rest")
        let kids = try BoxGrammar.children(c.rest(), topLevel: false, limits: limits, count: &count)
        guard let avcC = kids.first(where: { $0.type == t("avcC") }) else { throw ParseFailure(offset: b.offset, rule: "avc1", reason: .mismatch(expected: "avcC")) }
        return .avc(fourCC: b.type, width: width, height: height, config: try parseAvcC(avcC.body))
    }

    /// AVCDecoderConfigurationRecord (ISO/IEC 14496-15 5.3.3.1).
    public static func parseAvcC(_ body: ByteSlice) throws(ParseFailure) -> AVCDecoderConfiguration {
        var c = body.cursor()
        _ = try c.u8("avcC.configurationVersion", require: "1") { $0 == 1 }
        let profile = try c.u8("avcC.AVCProfileIndication")
        let compat = try c.u8("avcC.profile_compatibility")
        let level = try c.u8("avcC.AVCLevelIndication")
        let lengthSize = Int(try c.u8("avcC.lengthSizeMinusOne") & 0x3) + 1
        guard lengthSize != 3 else { throw c.fail("avcC.lengthSizeMinusOne", .invalid("3-byte NAL lengths")) }
        let numSPS = Int(try c.u8("avcC.numOfSequenceParameterSets") & 0x1F)
        var sps: [ByteSlice] = []
        for _ in 0..<numSPS {
            let len = Int(try c.u16be("avcC.sps.length"))
            guard len > 0 else { throw c.fail("avcC.sps", .invalid("empty")) }
            sps.append(try c.bytes(len, "avcC.sps"))
        }
        let numPPS = Int(try c.u8("avcC.numOfPictureParameterSets"))
        var pps: [ByteSlice] = []
        for _ in 0..<numPPS {
            let len = Int(try c.u16be("avcC.pps.length"))
            guard len > 0 else { throw c.fail("avcC.pps", .invalid("empty")) }
            pps.append(try c.bytes(len, "avcC.pps"))
        }
        guard !sps.isEmpty, !pps.isEmpty else { throw c.fail("avcC", .invalid("no SPS or PPS")) }
        // High-profile extension (chroma_format, bit depths, SPS ext) may follow; not needed here.
        return AVCDecoderConfiguration(profile: profile, compatibility: compat, level: level, nalLengthSize: lengthSize,
                                       sequenceParameterSets: sps, pictureParameterSets: pps)
    }

    static func parseMP4AEntry(_ b: Box, limits: MP4Limits, count: inout Int) throws(ParseFailure) -> SampleEntry {
        var c = b.body.cursor()
        try c.skip(6 + 2, "AudioSampleEntry.reserved")
        let version = try c.u16be("AudioSampleEntry.version")
        try c.skip(6, "AudioSampleEntry.reserved2")
        let channels = Int(try c.u16be("AudioSampleEntry.channelcount"))
        _ = try c.u16be("AudioSampleEntry.samplesize")
        try c.skip(4, "AudioSampleEntry.pre_defined")
        let rate = Int(try c.u32be("AudioSampleEntry.samplerate") >> 16)
        // QuickTime sound description versions 1 and 2 carry extra fields.
        if version == 1 { try c.skip(16, "AudioSampleEntry.v1") } else if version == 2 { try c.skip(36, "AudioSampleEntry.v2") }
        let kids = try BoxGrammar.children(c.rest(), topLevel: false, limits: limits, count: &count)
        let esds: Box
        if let e = kids.first(where: { $0.type == t("esds") }) {
            esds = e
        } else if let wave = kids.first(where: { $0.type == t("wave") }),
                  let e = try BoxGrammar.children(wave.body, topLevel: false, limits: limits, count: &count).first(where: { $0.type == t("esds") }) {
            esds = e
        } else {
            throw ParseFailure(offset: b.offset, rule: "mp4a", reason: .mismatch(expected: "esds"))
        }
        return .aac(channels: channels, sampleRate: rate, config: try parseEsds(esds.body))
    }

    /// ES_Descriptor (ISO/IEC 14496-1 7.2.6.5) → DecoderConfigDescriptor → DecoderSpecificInfo.
    public static func parseEsds(_ body: ByteSlice) throws(ParseFailure) -> AACConfiguration {
        var c = body.cursor()
        _ = try BoxGrammar.fullBox(&c)
        func descriptor(_ c: inout ByteCursor, expect tag: UInt8) throws(ParseFailure) -> ByteSlice {
            _ = try c.u8("descriptor.tag", require: "tag \(tag)") { $0 == tag }
            var length = 0
            for i in 0..<4 {
                let b = try c.u8("descriptor.length")
                length = length << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
                if i == 3 { throw c.fail("descriptor.length", .invalid("more than 4 bytes")) }
            }
            return try c.bytes(length, "descriptor.body")
        }
        var es = try descriptor(&c, expect: 0x03).cursor()
        _ = try es.u16be("ES.ES_ID")
        let flags = try es.u8("ES.flags")
        if flags & 0x80 != 0 { _ = try es.u16be("ES.dependsOn_ES_ID") }
        if flags & 0x40 != 0 { try es.skip(Int(try es.u8("ES.URLlength")), "ES.URLstring") }
        if flags & 0x20 != 0 { _ = try es.u16be("ES.OCR_ES_Id") }
        var dc = try descriptor(&es, expect: 0x04).cursor()
        let oti = try dc.u8("DecoderConfig.objectTypeIndication")
        _ = try dc.u8("DecoderConfig.streamType")
        _ = try dc.u24be("DecoderConfig.bufferSizeDB")
        _ = try dc.u32be("DecoderConfig.maxBitrate")
        let avg = try dc.u32be("DecoderConfig.avgBitrate")
        let dsi = try descriptor(&dc, expect: 0x05)
        guard !dsi.isEmpty else { throw dc.fail("DecoderSpecificInfo", .invalid("empty")) }
        return AACConfiguration(objectTypeIndication: oti, audioSpecificConfig: dsi, averageBitrate: avg)
    }

    // MARK: sample table

    static func sampleTable(_ st: [Box], stbl: Box, fileSize: Int, limits: MP4Limits, totalSamples: inout Int) throws(ParseFailure) -> [MP4Sample] {
        func box(_ name: String) -> Box? { st.first { $0.type == t(name) } }
        func table(_ b: Box, entrySize: Int) throws(ParseFailure) -> (ByteCursor, Int, UInt8) {
            var c = b.body.cursor()
            let (version, _) = try BoxGrammar.fullBox(&c)
            let n = Int(try c.u32be("\(b.type.fourCCString).entry_count"))
            guard n <= limits.maxTableEntries, n.multipliedReportingOverflow(by: entrySize).partialValue <= c.remaining,
                  !n.multipliedReportingOverflow(by: entrySize).overflow else {
                throw c.fail(b.type.fourCCString, .limitExceeded("\(n) entries"))
            }
            return (c, n, version)
        }

        // Sizes (stsz or stz2).
        var sizes: [Int] = []
        if let stsz = box("stsz") {
            var c = stsz.body.cursor()
            _ = try BoxGrammar.fullBox(&c)
            let fixed = Int(try c.u32be("stsz.sample_size"))
            let n = Int(try c.u32be("stsz.sample_count"))
            guard n <= limits.maxSamples, totalSamples + n <= limits.maxSamples else { throw c.fail("stsz", .limitExceeded("samples")) }
            if fixed != 0 {
                sizes = Array(repeating: fixed, count: n)
            } else {
                guard n * 4 <= c.remaining else { throw c.fail("stsz", .unexpectedEnd(needed: n * 4, available: c.remaining)) }
                sizes.reserveCapacity(n)
                for _ in 0..<n { sizes.append(Int(try c.u32be("stsz.entry_size"))) }
            }
        } else if let stz2 = box("stz2") {
            var c = stz2.body.cursor()
            _ = try BoxGrammar.fullBox(&c)
            try c.skip(3, "stz2.reserved")
            let field = Int(try c.u8("stz2.field_size", require: "4, 8 or 16") { [4, 8, 16].contains($0) })
            let n = Int(try c.u32be("stz2.sample_count"))
            guard n <= limits.maxSamples, totalSamples + n <= limits.maxSamples, (n * field + 7) / 8 <= c.remaining else { throw c.fail("stz2", .limitExceeded("samples")) }
            sizes.reserveCapacity(n)
            var i = 0
            while i < n {
                switch field {
                case 16: sizes.append(Int(try c.u16be("stz2.entry")))
                case 8: sizes.append(Int(try c.u8("stz2.entry")))
                default:
                    let b = try c.u8("stz2.entry")
                    sizes.append(Int(b >> 4))
                    if i + 1 < n { sizes.append(Int(b & 0xF)); i += 1 }
                }
                i += 1
            }
        } else {
            throw ParseFailure(offset: stbl.offset, rule: "stbl", reason: .mismatch(expected: "stsz or stz2"))
        }
        let n = sizes.count
        totalSamples += n
        if n == 0 { return [] }

        // Chunk offsets.
        var chunkOffsets: [Int] = []
        if let stco = box("stco") {
            var (c, k, _) = try table(stco, entrySize: 4)
            chunkOffsets.reserveCapacity(k)
            for _ in 0..<k { chunkOffsets.append(Int(try c.u32be("stco.chunk_offset"))) }
        } else if let co64 = box("co64") {
            var (c, k, _) = try table(co64, entrySize: 8)
            chunkOffsets.reserveCapacity(k)
            for _ in 0..<k {
                let o = try c.u64be("co64.chunk_offset")
                guard o <= UInt64(Int.max) else { throw c.fail("co64", .invalid("offset")) }
                chunkOffsets.append(Int(o))
            }
        } else {
            throw ParseFailure(offset: stbl.offset, rule: "stbl", reason: .mismatch(expected: "stco or co64"))
        }

        // Sample-to-chunk: runs of (first_chunk, samples_per_chunk, description_index).
        guard let stscBox = box("stsc") else { throw ParseFailure(offset: stbl.offset, rule: "stbl", reason: .mismatch(expected: "stsc")) }
        var (sc, scCount, _) = try table(stscBox, entrySize: 12)
        var runs: [(first: Int, perChunk: Int, desc: Int)] = []
        for _ in 0..<scCount {
            let first = Int(try sc.u32be("stsc.first_chunk")), per = Int(try sc.u32be("stsc.samples_per_chunk")), desc = Int(try sc.u32be("stsc.sample_description_index"))
            guard first >= 1, per >= 1, per <= limits.maxSamples, runs.last.map({ first > $0.first }) ?? true else {
                throw sc.fail("stsc", .invalid("run (\(first), \(per))"))
            }
            runs.append((first, per, desc))
        }
        guard !runs.isEmpty, runs[0].first == 1 else { throw sc.fail("stsc", .invalid("must start at chunk 1")) }

        var samples: [MP4Sample] = []
        samples.reserveCapacity(n)
        var index = 0
        for (r, run) in runs.enumerated() {
            let lastChunk = r + 1 < runs.count ? runs[r + 1].first - 1 : chunkOffsets.count
            guard lastChunk <= chunkOffsets.count else { throw ParseFailure(offset: stscBox.offset, rule: "stsc", reason: .invalid("chunk beyond stco")) }
            var chunk = run.first
            while chunk <= lastChunk, index < n {
                var offset = chunkOffsets[chunk - 1]
                for _ in 0..<run.perChunk where index < n {
                    let size = sizes[index]
                    let (end, overflow) = offset.addingReportingOverflow(size)
                    guard !overflow, end <= fileSize else {
                        throw ParseFailure(offset: stscBox.offset, rule: "sample", reason: .invalid("sample \(index) at \(offset)+\(size) outside the file"))
                    }
                    samples.append(MP4Sample(offset: offset, size: size, decodeTime: 0, compositionTime: 0, isSync: true, descriptionIndex: run.desc))
                    offset = end
                    index += 1
                }
                chunk += 1
            }
        }
        guard index == n else { throw ParseFailure(offset: stscBox.offset, rule: "stsc", reason: .invalid("\(index) of \(n) samples in chunks")) }

        // Decode times.
        guard let sttsBox = box("stts") else { throw ParseFailure(offset: stbl.offset, rule: "stbl", reason: .mismatch(expected: "stts")) }
        var (tc, tCount, _) = try table(sttsBox, entrySize: 8)
        var dts: Int64 = 0
        index = 0
        for _ in 0..<tCount {
            let k = Int(try tc.u32be("stts.sample_count")), delta = Int64(try tc.u32be("stts.sample_delta"))
            for _ in 0..<k where index < n {
                samples[index].decodeTime = dts
                samples[index].compositionTime = dts
                let (next, o) = dts.addingReportingOverflow(delta)
                guard !o else { throw tc.fail("stts", .invalid("time overflow")) }
                dts = next
                index += 1
            }
        }
        guard index == n else { throw tc.fail("stts", .invalid("\(index) of \(n) samples timed")) }

        // Composition offsets.
        if let cttsBox = box("ctts") {
            var (cc, cCount, version) = try table(cttsBox, entrySize: 8)
            index = 0
            for _ in 0..<cCount {
                let k = Int(try cc.u32be("ctts.sample_count"))
                let raw = try cc.u32be("ctts.sample_offset")
                // Version 0 is unsigned by the spec, but writers put negative values there too.
                let off = version == 1 || raw > 0x7FFF_FFFF ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                for _ in 0..<k where index < n {
                    samples[index].compositionTime = samples[index].decodeTime + off
                    index += 1
                }
            }
        }

        // Sync samples.
        if let stssBox = box("stss") {
            var (sc2, sCount, _) = try table(stssBox, entrySize: 4)
            for i in samples.indices { samples[i].isSync = false }
            for _ in 0..<sCount {
                let s = Int(try sc2.u32be("stss.sample_number"))
                guard s >= 1, s <= n else { throw sc2.fail("stss", .invalid("sample \(s) of \(n)")) }
                samples[s - 1].isSync = true
            }
        }
        return samples
    }
}

// MARK: stories

public enum VideoStoryCheck: Sendable, Equatable {
    case good
    case tooLong(maxSeconds: Double)
    case unsupportedCodec
    case unreadable
}

extension MP4File {
    /// `MAX_VIDEO_DURATION_IN_SEC`
    public static let maxStoryDurationSeconds = 30.999

    /// `isVideoGoodForStories` (after the size check, which the caller makes): at most
    /// 30.999 s (movie duration) and an `avc1` track.
    public var storyCheck: VideoStoryCheck {
        if durationSeconds > Self.maxStoryDurationSeconds { return .tooLong(maxSeconds: Self.maxStoryDurationSeconds) }
        let hasAVC1 = tracks.contains { $0.sampleEntries.contains { $0.fourCC == FourCC("avc1") } }
        return hasAVC1 ? .good : .unsupportedCodec
    }

    public static func storyCheck(_ bytes: [UInt8]) -> VideoStoryCheck {
        guard let f = try? MP4Demuxer.parse(bytes) else { return .unreadable }
        return f.storyCheck
    }
}
