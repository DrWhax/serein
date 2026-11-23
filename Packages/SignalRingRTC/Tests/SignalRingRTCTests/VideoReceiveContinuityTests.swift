// RingRTC negotiates RED/ULPFEC for direct-call video, so FEC packets (and padding) take RTP
// sequence numbers between pictures. Their gap is not a lost picture: resetting the decoder there
// made every following picture undecodable, and each failure requested a keyframe (a stock
// Android sender then fell to 240x96 at about three keyframes a second).

import Foundation
@testable import SwiftCalling
import Testing
import VideoVP9

@Suite struct VideoReceiveContinuityTests {
    private static let width = 64, height = 48

    /// A keyframe and three inter pictures from the Swift VP9 encoder (a moving bar).
    private static func pictures() -> [[UInt8]] {
        var encoder = VP9VideoEncoder()
        return (0..<4).map { index in
            var y = [UInt8](repeating: 60, count: width * height)
            for row in 0..<height { for column in (index * 8)..<(index * 8 + 8) { y[row * width + column] = 200 } }
            let chroma = [UInt8](repeating: 128, count: (width / 2) * (height / 2))
            return encoder.encode(width: width, height: height, y: y, u: chroma, v: chroma, keyframe: index == 0)!
        }
    }

    private func frame(_ bytes: [UInt8], picture: Int?, sequence: UInt16, timestamp: UInt32) -> VP9Assembly.Frame {
        VP9Assembly.Frame(bytes: Data(bytes), spatialLayer: 0, rotation: 0, timestamp: timestamp, start: sequence, end: sequence,
                          pictureID: picture, pictureIDMask: 0x7fff)
    }

    private func run(_ frames: [VP9Assembly.Frame]) async throws -> (completed: UInt64, refreshes: Int, diagnostics: DirectCallVideo.ReceiveDiagnostics) {
        let video = DirectCallVideo()
        let refreshes = Counter()
        video.startReceiving { await refreshes.bump() }
        for frame in frames { video.decode(frame, ssrc: 2003) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let done = (video.frameStats(ssrc: 2003, outgoing: false)?.completed ?? 0) + UInt64(await refreshes.value)
            if done >= UInt64(frames.count) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        let result = (video.frameStats(ssrc: 2003, outgoing: false)?.completed ?? 0, await refreshes.value, video.receiveDiagnostics())
        video.close()
        return result
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    @Test func aSequenceGapBetweenConsecutivePicturesIsNotALoss() async throws {
        let p = Self.pictures()
        // Sequence 11 and 14 were FEC packets: consecutive picture IDs, discontiguous sequence.
        let (completed, refreshes, diagnostics) = try await run([
            frame(p[0], picture: 700, sequence: 10, timestamp: 0),
            frame(p[1], picture: 701, sequence: 12, timestamp: 3000),
            frame(p[2], picture: 702, sequence: 13, timestamp: 6000),
            frame(p[3], picture: 703, sequence: 15, timestamp: 9000),
        ])
        #expect(completed == 4 && refreshes == 0, "\(diagnostics.summary)")
        #expect(diagnostics.gapResets == 0 && diagnostics.errors.isEmpty)
    }

    @Test func aMissingPictureStillResetsAndRequestsAKeyframe() async throws {
        let p = Self.pictures()
        // Picture 702 never arrived: both its sequence numbers and its ID are missing.
        let (completed, refreshes, diagnostics) = try await run([
            frame(p[0], picture: 700, sequence: 10, timestamp: 0),
            frame(p[1], picture: 701, sequence: 11, timestamp: 3000),
            frame(p[3], picture: 703, sequence: 13, timestamp: 9000),
        ])
        #expect(diagnostics.gapResets == 1, "\(diagnostics.summary)")
        #expect(completed == 2 && refreshes == 1, "\(diagnostics.summary)")
    }

    @Test func pictureIDsAreReadFromTheDescriptor() throws {
        var stream = VP9Assembly()
        func packet(_ seq: UInt16, _ bytes: [UInt8]) -> RTPPayload {
            RTPPayload(type: 109, timestamp: 90, sequence: seq, marker: true, rotation: 0, transportNumber: nil, bytes: Data(bytes))
        }
        // I, B and E with a 15-bit picture ID 0x1234, then with a 7-bit one.
        let long = try stream.assemble(packet(1, [0x8c, 0x80 | 0x12, 0x34, 0xa0]))
        #expect(long.first?.pictureID == 0x1234 && long.first?.pictureIDMask == 0x7fff)
        var next = VP9Assembly()
        let short = try next.assemble(packet(2, [0x8c, 0x45, 0xa0]))
        #expect(short.first?.pictureID == 0x45 && short.first?.pictureIDMask == 0x7f)
    }
}
