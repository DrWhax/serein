// Video sessions' resource limits: each decoder is held to the picture size its container
// declares, and the open videos to a memory budget; idle ones are closed to make room, after
// a long idle time, or under memory pressure.

import Foundation
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

struct VideoSessionLimitTests {
    static func bytes(_ name: String) -> [UInt8] { [UInt8](VideoServiceTests.bytes(name)) }

    /// `name` with its video sample entry declaring `width` x `height` (the entry follows its
    /// stsd's header; width and height are 28 bytes after its type).
    static func declaring(_ name: String, width: Int, height: Int) throws -> [UInt8] {
        var b = bytes(name)
        let video = ["avc1", "avc3", "hvc1", "hev1", "av01"].map { Array($0.utf8) }
        let stsd = Array("stsd".utf8)
        let entry = try #require((4 ..< b.count - 48).first { i in Array(b[i ..< i + 4]) == stsd && video.contains(Array(b[i + 16 ..< i + 20])) }) + 16
        b[entry + 28] = UInt8(width >> 8); b[entry + 29] = UInt8(width & 0xFF)
        b[entry + 30] = UInt8(height >> 8); b[entry + 31] = UInt8(height & 0xFF)
        return b
    }

    /// A container declaring a smaller picture than its parameter sets hold: H.264 and HEVC
    /// refuse the parameter sets at once, AV1 each frame (its size is in the frame headers).
    @Test(arguments: ["baseline_p_cavlc_ref3.mp4", "hlg10.mp4", "av1_svt_gop6.mp4"]) func decoderIsHeldToTheContainerSize(_ name: String) throws {
        var honest = try VideoStream(Self.bytes(name), deep: true)
        #expect(!honest.frames(1).isEmpty)
        let lying = try Self.declaring(name, width: 32, height: 32)
        if name.hasPrefix("av1") {
            var s = try VideoStream(lying, deep: true)
            #expect(s.admitted == (64, 64))
            #expect(s.frames(2).isEmpty)
        } else {
            #expect(throws: (any Error).self) { try VideoStream(lying, deep: true) }
        }
    }

    /// The admitted size is the container's rounded up to 64, so coded sizes above the
    /// displayed one (macroblock or CTB alignment, cropping) still decode.
    @Test func admittedSizeCoversCodedAlignment() throws {
        var s = try VideoStream(Self.bytes("high_odd_size_crop.mp4"), deep: true)
        #expect(s.admitted == (256, 128))
        #expect(s.frames(10).count == 10)
    }

    static func estimate(_ name: String) throws -> Int { try VideoStream(Self.bytes(name), deep: true).estimatedBytes }

    @Test func aVideoLargerThanTheBudgetIsRefused() async throws {
        let need = try Self.estimate("baseline_p_cavlc_ref3.mp4")
        #expect(need > Self.bytes("baseline_p_cavlc_ref3.mp4").count)
        let sessions = VideoSessions(budget: need - 1)
        await #expect(throws: MediaProcessingError.self) { try await sessions.open(Self.bytes("baseline_p_cavlc_ref3.mp4")) }
    }

    /// Room for two: the third video closes the one used longest ago, if it has been idle long
    /// enough; else it is refused.
    @Test(arguments: [true, false]) func theBudgetClosesTheLeastRecentlyUsedIdleVideo(_ idleEnough: Bool) async throws {
        let name = "baseline_p_cavlc_ref3.mp4"
        let need = try Self.estimate(name)
        let sessions = VideoSessions(budget: 2 * need + need / 2, evictableAfter: idleEnough ? .zero : .seconds(3600))
        let a = try await sessions.open(Self.bytes(name)).session
        let b = try await sessions.open(Self.bytes(name)).session
        _ = try await sessions.frames(a, count: 1)
        if idleEnough {
            let c = try await sessions.open(Self.bytes(name)).session
            #expect(try await !sessions.frames(a, count: 1).isEmpty)
            #expect(try await !sessions.frames(c, count: 1).isEmpty)
            await #expect(throws: MediaProcessingError.self) { try await sessions.frames(b, count: 1) }
        } else {
            await #expect(throws: MediaProcessingError.self) { try await sessions.open(Self.bytes(name)) }
            #expect(await sessions.count == 2)
        }
    }

    @Test func longIdleVideosAreClosed() async throws {
        let sessions = VideoSessions(idleTimeout: .zero)
        let a = try await sessions.open(Self.bytes("baseline_p_cavlc_ref3.mp4")).session
        _ = try await sessions.open(Self.bytes("baseline_p_cavlc_ref3.mp4"))
        await #expect(throws: MediaProcessingError.self) { try await sessions.frames(a, count: 1) }
    }

    /// Memory pressure closes idle videos: a warning those idle for `evictableAfter`, a
    /// critical event those idle for five seconds (so not one just used).
    @Test func memoryPressureClosesIdleVideos() async throws {
        let sessions = VideoSessions(evictableAfter: .zero)
        _ = try await sessions.open(Self.bytes("baseline_p_cavlc_ref3.mp4"))
        _ = try await sessions.open(Self.bytes("av1_svt_gop6.mp4"))
        await sessions.shed(critical: true)
        #expect(await sessions.count == 2)
        await sessions.shed(critical: false)
        #expect(await sessions.count == 0)
    }
}
