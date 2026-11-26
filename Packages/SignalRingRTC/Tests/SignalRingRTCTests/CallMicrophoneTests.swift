import Foundation
import Testing
@testable import SwiftCalling

struct CallMicrophoneTests {
    #if os(Linux)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_ALSA_CHECK"] != nil))
    func runningCaptureSurvivesAFailedDeviceChange() async throws {
        let mic = CallMicrophone(uid: "checkin")
        let stream = try await mic.start()
        await #expect(throws: CallMicrophone.Failure.busy) { try await mic.warmUp() }
        await #expect(throws: CallMicrophone.Failure.unavailable) { try await mic.select("missing-device") }
        var reader = stream.makeAsyncIterator()
        let frame = try #require(await reader.next())
        #expect(frame == (0..<960).map { Int16($0 % 400 - 200) })
        await mic.stop()
        try await mic.warmUp()
        await mic.stop()
    }
    #else
    @Test func cancellationDoesNotWaitForAStalledDevice() async throws {
        let queue = DispatchQueue(label: "call.microphone.test")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        defer { release.signal() }
        let driver = try SelectedMicrophone(uid: "unavailable", sink: nil, echo: nil,
                                            activity: CaptureActivity(), queue: queue) {}
        let start = ContinuousClock.now
        await #expect(throws: CallMicrophone.Failure.unavailable) {
            try await driver.start(deadline: .milliseconds(30))
        }
        driver.close()
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func hardwareRatesPreservePhaseAcrossCallbackBoundaries() throws {
        for hz in [44_100, 48_000, 96_000] {
            let input = (0..<hz/20).map { Float(sin(Double($0) * 0.13)) }
            var whole = try #require(MicrophonePCM(sampleRate: hz)), chunked = whole
            let expected = whole.append(input.span)
            var blocks: [[Int16]] = []
            for i in stride(from: 0, to: input.count, by: 211) {
                blocks += chunked.append(input.span.extracting(i..<min(input.count,i+211)))
            }
            #expect(expected.count == 2 && blocks == expected)
        }
        var pcm = try #require(MicrophonePCM(sampleRate: 48_000))
        var raw = [Float](repeating: 0, count: 960)
        raw.replaceSubrange(0..<4, with: [-2, 2, .infinity, .nan])
        let block = try #require(pcm.append(raw.span).first)
        #expect(Array(block.prefix(4)) == [.min, .max, 0, 0])
    }

    @Test func preservesPCMAndTimestampAcrossCaptureChunks() throws {
        var pcm = CapturedPCM()
        #expect(pcm.append(bytes: Data([0xff]), firstFrame: 0).isEmpty)
        var first = Data([0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0xff, 0x7f])
        first.append(Data(repeating: 0, count: 1192))
        #expect(pcm.append(bytes: first, firstFrame: 1200).isEmpty)
        let frames = pcm.append(bytes: Data(repeating: 0, count: 2640), firstFrame: 1800)
        #expect(frames.map(\.at) == [1200, 2160])
        #expect(frames.allSatisfy { $0.samples.count == 960 })
        #expect(frames.first.map { Array($0.samples.prefix(4)) } == [.min, -1, 0, .max])
    }

    @Test func discardsPartialFrameAcrossDiscontinuity() {
        var pcm = CapturedPCM()
        #expect(pcm.append(bytes: Data(repeating: 0xff, count: 960), firstFrame: 0).isEmpty)
        let frames = pcm.append(bytes: Data(repeating: 0, count: 1920), firstFrame: 30_000)
        #expect(frames.first?.at == 30_000)
        #expect(frames.first?.samples == [Int16](repeating: 0, count: 960))
    }
    #endif
}
