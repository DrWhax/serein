#if os(Linux)
import CLinuxCallAudio
import Foundation

actor CallSpeaker {
    enum Failure: Error { case unavailable, invalidFrame, closed }
    private let muted: Bool
    private var uid: String?
    private let echo: CallEchoControl?
    private let started: (@Sendable (Bool, String?) -> Void)?
    private var handle: UInt64 = 0
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
        guard handle != 0 else { return }
        stop()
        do { try start() } catch {
            uid = previous
            try? start()
            throw error
        }
    }

    func start() throws {
        guard handle == 0 else { return }
        handle = serein_call_pcm_open(Array((uid ?? "").utf8).span, 0)
        started?(handle != 0, uid)
        guard handle != 0 else { throw Failure.unavailable }
    }

    func enqueue(_ samples: [Int16], timestamp: UInt32) throws {
        _ = try enqueueForPresentation(samples, timestamp: timestamp)
    }

    func enqueueForPresentation(_ samples: [Int16], timestamp: UInt32) throws -> ContinuousClock.Instant? {
        guard handle != 0 else { throw Failure.closed }
        guard (120...5760).contains(samples.count), samples.count.isMultiple(of: 120) else { throw Failure.invalidFrame }
        let host = ContinuousClock.now
        let now = CallEchoControl.hostFrame
        guard let slot = timeline.schedule(timestamp: timestamp, count: samples.count, now: now) else { return nil }
        if slot.flush { echo?.reset() }
        let result = serein_call_pcm_play(handle, samples.span, slot.frame, slot.flush ? 1 : 0, muted ? 1 : 0)
        guard result.status == 1 else {
            timeline = SpeakerTimeline()
            echo?.reset()
            if result.status < 0 { throw Failure.unavailable }
            return nil
        }
        if !muted { echo?.render(samples, at: result.first_frame) }
        return host + .seconds(Double(result.first_frame - now) / 48000)
    }

    func stop() {
        serein_call_pcm_close(handle)
        handle = 0
        echo?.reset()
        timeline = SpeakerTimeline()
    }
    isolated deinit { serein_call_pcm_close(handle) }
}
#endif
