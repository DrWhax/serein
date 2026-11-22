import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Presents decoded, mono 48 kHz PCM to the selected audio output.
actor CallSpeaker {
    enum Failure: Error { case unavailable, invalidFrame, closed }

    private let muted: Bool
    private var uid: String?
    private let echo: CallEchoControl?
    private let started: (@Sendable (Bool, String?) -> Void)?
    private var output: AVSampleBufferRenderSynchronizer?
    private var receiver: AVSampleBufferAudioRenderer.Receiver?
    private var pcm: SpeakerPCM?
    private var timeline = SpeakerTimeline()

    init(muted: Bool = false, uid: String? = nil, echo: CallEchoControl? = nil, started: (@Sendable (Bool, String?) -> Void)? = nil) {
        self.muted = muted
        self.uid = uid
        self.echo = echo
        self.started = started
    }

    func select(_ next: String?) throws {
        guard uid != next else { return }
        let previous = uid
        uid = next
        guard output != nil else { return }
        // Changing the output changes the renderer's timebase. A fresh renderer also restores
        // system-default routing when switching away from an explicit device.
        stop()
        do { try start() } catch {
            uid = previous
            try? start()
            throw error
        }
    }

    func start() throws {
        guard output == nil else { return }
        do {
            try makeRenderer()
            started?(true, uid)
        } catch {
            started?(false, uid)
            throw error
        }
    }

    private func makeRenderer() throws {
        let system = AudioHardwareSystem.shared
        let device = try uid.map { try system.device(forUID: $0) } ?? system.defaultOutputDevice
        guard device != nil else { throw Failure.unavailable }
        let pcm = try SpeakerPCM()
        let renderer = AVSampleBufferAudioRenderer()
        renderer.isMuted = muted
        if let uid { renderer.audioOutputDeviceUniqueID = uid }
        let output = AVSampleBufferRenderSynchronizer()
        output.delaysRateChangeUntilHasSufficientMediaData = false
        receiver = output.sampleBufferReceiver(adding: renderer)
        self.pcm = pcm
        self.output = output
    }

    func enqueue(_ samples: [Int16], timestamp: UInt32) throws {
        _ = try enqueueForPresentation(samples, timestamp: timestamp)
    }

    func enqueueForPresentation(_ samples: [Int16], timestamp: UInt32) throws -> ContinuousClock.Instant? {
        guard let output, let receiver, let pcm else { throw Failure.closed }
        guard (120...5760).contains(samples.count), samples.count.isMultiple(of: 120) else {
            throw Failure.invalidFrame
        }
        let host = ContinuousClock.now
        let now = output.currentTime().convertScale(48_000, method: .default)
        guard now.isNumeric else { throw Failure.unavailable }
        guard let slot = timeline.schedule(timestamp: timestamp, count: samples.count, now: now.value) else { return nil }
        if slot.flush { receiver.flush(); echo?.reset() }
        let block = pcm.buffer(samples, at: slot.frame)
        switch receiver.enqueueImmediately(CMReadySampleBuffer(block)) {
        case .enqueued:
            if !muted { echo?.render(samples, at: CallEchoControl.hostFrame + slot.frame - now.value) }
        case .enqueuedWithSuggestedFlush, .cancelledDueToFlush:
            receiver.flush()
            timeline = SpeakerTimeline()
            echo?.reset()
            return nil
        case .cancelledDueToError(let error): throw error
        @unknown default: throw Failure.unavailable
        }
        if output.rate == 0 { output.setRate(1, time: now) }
        return host + .seconds(Double(slot.frame - now.value) / 48000)
    }

    func stop() {
        output?.rate = 0
        receiver?.flush()
        receiver = nil
        echo?.reset()
        output = nil
        pcm = nil
        timeline = SpeakerTimeline()
    }

    isolated deinit {
        output?.rate = 0
        receiver?.flush()
    }
}

/// The renderer accepts only signed PCM in this format, built from decoded samples.
struct SpeakerPCM {
    private let format: CMAudioFormatDescription

    init() throws {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        format = try CMAudioFormatDescription(audioStreamBasicDescription: description)
    }

    func buffer(_ samples: [Int16], at frame: Int64) -> CMReadySampleBuffer<CMReadOnlyDataBlockBuffer> {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let word = UInt16(bitPattern: sample)
            bytes.append(UInt8(truncatingIfNeeded: word))
            bytes.append(UInt8(word >> 8))
        }
        return CMReadySampleBuffer(audioDataBuffer: CMReadOnlyDataBlockBuffer(bytes),
                                   formatDescription: format, sampleCount: samples.count,
                                   presentationTimeStamp: CMTime(value: frame, timescale: 48_000))
    }
}

/// Places RTP timestamps on the output device's 48 kHz clock, including wrap and loss.
/// Leave 60 ms of headroom on startup or underrun. Limit queued speech to 360 ms.
struct SpeakerTimeline {
    struct Slot {
        let frame: Int64
        let flush: Bool
    }

    private var nextTimestamp: UInt32?
    private var endFrame: Int64 = 0

    mutating func schedule(timestamp: UInt32, count: Int, now: Int64) -> Slot? {
        let gap = nextTimestamp.map { Int64(Int32(bitPattern: timestamp &- $0)) } ?? 0
        guard gap >= 0 else { return nil }
        var frame = endFrame + gap
        let lead: Int64 = 2880
        let capacity: Int64 = 17_280
        let restart = nextTimestamp == nil || frame < now || gap > capacity
        if restart { frame = now + lead }
        guard frame + Int64(count) <= now + capacity else { return nil }
        let flush = restart && nextTimestamp != nil
        endFrame = frame + Int64(count)
        nextTimestamp = timestamp &+ UInt32(count)
        return Slot(frame: frame, flush: flush)
    }
}
