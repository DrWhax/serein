// ContainerMP4 against ffprobe (Tools/gen-codec-references.py mp4): every track and every
// sample — size, file offset, decode and presentation time after the edit list, keyframe.

import CodecCore
import Foundation
import Testing
@testable import ContainerMP4

struct MP4ReferenceTests {
    struct Ref: Decodable {
        struct Stream: Decodable {
            var index: Int; var codec_name: String; var codec_type: String; var width: Int?; var height: Int?
            var sample_rate: String?; var channels: Int?; var time_base: String; var nb_frames: String?; var rotation: Int?
        }
        var streams: [Stream]
        var packets: [[Int?]]   // stream, pts, dts, size, pos (keyframe is a Bool, read separately)
        var duration: Double
    }

    static func refs() throws -> [String: Ref] {
        // packets carry a Bool last; decode them as raw JSON to split it off.
        let data = Data(Resources.bytes("MP4/ffprobe.json"))
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        var out: [String: Ref] = [:]
        for (name, v) in raw {
            let streams = try JSONDecoder().decode([Ref.Stream].self, from: JSONSerialization.data(withJSONObject: v["streams"]!))
            let packets = (v["packets"] as! [[Any]]).map { p in p.map { ($0 as? NSNumber).map { n in CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? 1 : 0) : n.intValue } } }
            out[name] = Ref(streams: streams, packets: packets, duration: (v["duration"] as! NSNumber).doubleValue)
        }
        return out
    }

    @Test(arguments: ["high_bframes_aac_faststart.mp4", "high_bframes_aac_moov_at_end.mp4", "baseline_video_only.mp4", "main_rotated_90.mp4",
                      "aac_mono_22050.m4a", "gif_like_64x64_faststart.mp4"])
    func matchesFFprobe(_ name: String) throws {
        let ref = try #require(try Self.refs()[name])
        let file = try MP4Demuxer.parse(Resources.bytes("MP4/" + name))
        #expect(file.tracks.count == ref.streams.count)
        #expect(abs(file.durationSeconds - ref.duration) < 0.05, "\(file.durationSeconds) vs \(ref.duration)")
        #expect(file.moovBeforeMdat == name.contains("faststart"))   // ffmpeg writes moov last unless +faststart
        for (track, stream) in zip(file.tracks, ref.streams) {
            #expect(stream.time_base == "1/\(track.timescale)")
            #expect(Int(stream.nb_frames ?? "-1") == track.samples.count)
            switch track.sampleEntries.first {
            case .avc(_, let w, let h, let config)?:
                #expect(stream.codec_name == "h264" && track.kind == .video && w == stream.width && h == stream.height)
                #expect(config.nalLengthSize == 4 && !config.sequenceParameterSets.isEmpty)
                #expect(track.rotation == (360 - (stream.rotation ?? 0)) % 360)   // ffprobe: counter-clockwise
            case .aac(let channels, let rate, let config)?:
                #expect(stream.codec_name == "aac" && track.kind == .audio && channels == stream.channels && "\(rate)" == stream.sample_rate)
                #expect(config.objectTypeIndication == 0x40 && config.audioSpecificConfig.count >= 2)
            default:
                Issue.record("unexpected sample entry \(String(describing: track.sampleEntries.first))")
            }
            let packets = ref.packets.filter { $0[0] == stream.index }
            #expect(packets.count == track.samples.count)
            let shift = track.presentationOffset
            for (s, p) in zip(track.samples, packets) {
                #expect(s.size == p[3] && s.offset == p[4] && s.isSync == (p[5] == 1), "\(name) sample at \(s.offset)")
                #expect(s.decodeTime - shift == Int64(p[2] ?? Int.min) && s.compositionTime - shift == Int64(p[1] ?? Int.min),
                        "\(name) times \(s.decodeTime) \(s.compositionTime) vs \(String(describing: p[2])) \(String(describing: p[1]))")
            }
        }
        #expect(file.storyCheck == (file.videoTracks.isEmpty ? .unsupportedCodec : .good))
    }
}

/// Hand-built files for paths ffmpeg does not produce, and hostile structures.
struct MP4StructureTests {
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(8 + body.count)) + Array(type.utf8) + body }
    static func full(_ type: String, _ version: UInt8 = 0, _ body: [UInt8]) -> [UInt8] { box(type, [version, 0, 0, 0] + body) }

    /// A one-track file: `samples` sizes in one chunk at `chunkOffset`, optional co64/stz2.
    static func file(sizes: [UInt32], co64: Bool = false, stz2: Bool = false, timescale: UInt32 = 1000, duration: UInt32 = 2000,
                     matrix: [Int32] = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000], mdatPadding: Int = 0) -> [UInt8] {
        let tkhd = full("tkhd", 0, be32(0) + be32(0) + be32(1) + be32(0) + be32(duration) + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 0, 0, 0, 0, 0]
                        + matrix.flatMap { be32(UInt32(bitPattern: $0)) } + be32(64 << 16) + be32(48 << 16))
        let mdhd = full("mdhd", 0, be32(0) + be32(0) + be32(timescale) + be32(duration) + [0x55, 0xC4, 0, 0])
        let hdlr = full("hdlr", 0, be32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 12) + [0])
        let avcC = box("avcC", [1, 66, 0, 30, 0xFF, 0xE1, 0, 4, 0x67, 0x42, 0, 30, 1, 0, 2, 0x68, 0xCE])
        let avc1 = box("avc1", [UInt8](repeating: 0, count: 6) + [0, 1] + [UInt8](repeating: 0, count: 16) + [0, 64, 0, 48] + [0, 0x48, 0, 0, 0, 0x48, 0, 0]
                       + be32(0) + [0, 1] + [UInt8](repeating: 0, count: 32) + [0, 0x18, 0xFF, 0xFF] + avcC)
        let stsd = full("stsd", 0, be32(1) + avc1)
        let stts = full("stts", 0, be32(1) + be32(UInt32(sizes.count)) + be32(duration / UInt32(max(sizes.count, 1))))
        let stsc = full("stsc", 0, be32(1) + be32(1) + be32(UInt32(sizes.count)) + be32(1))
        let sizeBox = stz2 ? full("stz2", 0, [0, 0, 0, 16] + be32(UInt32(sizes.count)) + sizes.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
                           : full("stsz", 0, be32(0) + be32(UInt32(sizes.count)) + sizes.flatMap(be32))
        let ftyp = box("ftyp", Array("isom".utf8) + be32(512) + Array("isomavc1".utf8))
        func build(offset: UInt64) -> [UInt8] {
            let chunk = co64 ? full("co64", 0, be32(1) + be64(offset)) : full("stco", 0, be32(1) + be32(UInt32(offset)))
            let stbl = box("stbl", stsd + stts + stsc + sizeBox + chunk + full("stss", 0, be32(1) + be32(1)))
            let trak = box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", box("stbl", []).isEmpty ? [] : stbl)))
            let mvhd = full("mvhd", 0, be32(0) + be32(0) + be32(timescale) + be32(duration) + [UInt8](repeating: 0, count: 80))
            return ftyp + box("moov", mvhd + trak)
        }
        let head = build(offset: 0)
        let mdatBody = [UInt8](repeating: 0xAB, count: Int(sizes.reduce(0, +)) + mdatPadding)
        return build(offset: UInt64(head.count + 8)) + box("mdat", mdatBody)
    }

    @Test func co64Stz2AndRotation() throws {
        for (co64, stz2) in [(false, false), (true, false), (false, true), (true, true)] {
            let f = try MP4Demuxer.parse(Self.file(sizes: [100, 50, 7], co64: co64, stz2: stz2,
                                                   matrix: [0, 0x10000, 0, -0x10000, 0, 0, 0, 0, 0x4000_0000]))
            let t = try #require(f.tracks.first)
            #expect(t.samples.map(\.size) == [100, 50, 7] && t.samples[1].offset == t.samples[0].offset + 100)
            #expect(t.samples.map(\.isSync) == [true, false, false] && t.samples.map(\.decodeTime) == [0, 666, 1332])
            #expect(t.rotation == 90 && f.storyCheck == .good)
        }
    }

    @Test func storyLimits() throws {
        let long = try MP4Demuxer.parse(Self.file(sizes: [10], timescale: 1000, duration: 31_500))
        #expect(long.storyCheck == .tooLong(maxSeconds: 30.999))
        #expect(MP4File.storyCheck([1, 2, 3]) == .unreadable)
    }

    @Test func hostileStructures() {
        // Samples past the end of the file.
        var short = Self.file(sizes: [100, 50])
        short.removeLast(60)
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(short) }
        // A box claiming more bytes than its parent has.
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(Self.box("moov", Self.be32(0xFFFF) + Array("trak".utf8))) }
        // size < header, size 0 inside a container, no moov, two moovs, fragmented.
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(Self.be32(4) + Array("moov".utf8)) }
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(Self.box("moov", Self.be32(0) + Array("trak".utf8))) }
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(Self.box("ftyp", Array("isom".utf8) + Self.be32(0))) }
        let one = Self.file(sizes: [10])
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(Self.box("moov", []) + Self.box("moov", [])) }
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(one + Self.box("moof", [])) }
        // Huge table counts are refused before allocating.
        var huge = Self.file(sizes: [10])
        if let i = huge.indices.first(where: { i in i + 8 <= huge.count && Array(huge[i + 4..<i + 8]) == Array("stsz".utf8) }) {
            huge.replaceSubrange(i + 16..<i + 20, with: Self.be32(0x7FFF_FFFF))
        }
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(huge) }
        // Deep nesting stays bounded (no recursion beyond the fixed box levels).
        var nested: [UInt8] = []
        for _ in 0..<10_000 { nested = Self.box("moov", nested) }
        #expect(throws: ParseFailure.self) { try MP4Demuxer.parse(nested) }
    }
}
