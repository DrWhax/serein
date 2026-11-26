#if os(Linux)
import Foundation
#else
import CoreAudio
import CoreMedia
#endif
import Testing
@testable import SwiftCalling

struct CallSpeakerTests {
    #if os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_ALSA_CHECK"] != nil))
    func captureAndPlayThroughALSA() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SEREIN_ALSA_CHECK"]))
        let expected = (0..<960).map { Int16($0 % 400 - 200) }
        let mic = CallMicrophone(uid: "checkin")
        let stream = try await mic.start()
        var reader = stream.makeAsyncIterator()
        let frame = try #require(await reader.next())
        #expect(frame == expected)
        await mic.stop()

        let before = CallEchoControl.hostFrame
        let speaker = CallSpeaker(uid: "checkout")
        try await speaker.start()
        let presentation = try #require(try await speaker.enqueueForPresentation(frame, timestamp: .max - 400))
        #expect(presentation > .now)
        #expect(try await speaker.enqueueForPresentation(frame, timestamp: .max - 400) == nil)
        await speaker.stop()
        let output = try Data(contentsOf: directory.appendingPathComponent("speaker.raw"))
        let raw = expected.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
        #expect(output.count > raw.count && output.suffix(raw.count).elementsEqual(raw))
        #expect(output.dropLast(raw.count).allSatisfy { $0 == 0 })
        #expect(CallEchoControl.hostFrame > before)
        let muted = CallSpeaker(muted: true, uid: "checkmuted")
        try await muted.start()
        try await muted.enqueue(expected, timestamp: 0)
        await muted.stop()
        let silence = try Data(contentsOf: directory.appendingPathComponent("muted.raw"))
        #expect(silence.count >= raw.count && silence.allSatisfy { $0 == 0 })
    }
    #else
    @Test func rendersOnlyFixedFormatPCM() throws {
        let samples: [Int16] = [.min, -1, 0, 1, .max]
        let buffer = try SpeakerPCM().buffer(samples, at: 5760)
        let audio = try #require(buffer.formatDescription.audioStreamBasicDescription)
        #expect(audio.mFormatID == kAudioFormatLinearPCM)
        #expect(audio.mChannelsPerFrame == 1)
        #expect(audio.mSampleRate == 48_000)
        #expect(audio.mBitsPerChannel == 16)
        #expect(audio.mBytesPerFrame == 2)

        let bytes = buffer.content.regions.flatMap { Array($0) }
        #expect(bytes == [0, 128, 255, 255, 0, 0, 1, 0, 255, 127])
        #expect(buffer.sampleCount == samples.count)
        #expect(buffer.presentationTimeStamp == CMTime(value: 5760, timescale: 48_000))
        #expect(buffer.duration == CMTime(value: 5, timescale: 48_000))
    }

    #endif

    @Test func schedulesContiguousFramesAcrossWrapAndPreservesLoss() throws {
        var timeline = SpeakerTimeline()
        let offset = UInt32.max - 479
        let firstSlot = timeline.schedule(timestamp: offset, count: 960, now: 0)
        let first = try #require(firstSlot)
        #expect(first.frame == 2880 && !first.flush)
        let secondSlot = timeline.schedule(timestamp: 480, count: 960, now: 960)
        let second = try #require(secondSlot)
        #expect(second.frame == first.frame + 960 && !second.flush)
        #expect(timeline.schedule(timestamp: 480, count: 960, now: 1440) == nil)
        let gapSlot = timeline.schedule(timestamp: 2400, count: 960, now: 2880)
        let gap = try #require(gapSlot)
        #expect(gap.frame == second.frame + 1920 && !gap.flush)
    }

    @Test func boundsLatencyAndRecoversAfterDiscontinuities() throws {
        var timeline = SpeakerTimeline()
        for i in 0..<15 {
            #expect(timeline.schedule(timestamp: UInt32(i * 960), count: 960, now: 0) != nil)
        }
        #expect(timeline.schedule(timestamp: 14_400, count: 960, now: 0) == nil)
        let restartSlot = timeline.schedule(timestamp: 15_360, count: 960, now: 30_000)
        let restart = try #require(restartSlot)
        #expect(restart.flush && restart.frame == 32_880)
        let discontinuitySlot = timeline.schedule(timestamp: 0x7fff_ffff, count: 960, now: 32_880)
        let discontinuity = try #require(discontinuitySlot)
        #expect(discontinuity.flush && discontinuity.frame == 35_760)
    }
}
