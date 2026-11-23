import Foundation

package protocol VoiceCallMicrophone: Actor {
    func start() async throws -> AsyncStream<[Int16]>
    func stop()
}

package protocol VoiceCallSpeaker: Actor {
    func start() throws
    func enqueue(_ samples: [Int16], timestamp: UInt32) throws
    func enqueueForPresentation(_ samples: [Int16], timestamp: UInt32) throws -> ContinuousClock.Instant?
    func stop()
}

extension VoiceCallSpeaker {
    /// File and test devices consume their samples immediately.
    package func enqueueForPresentation(_ samples: [Int16], timestamp: UInt32) throws -> ContinuousClock.Instant? {
        try enqueue(samples, timestamp: timestamp)
        return .now
    }
}

extension CallMicrophone: VoiceCallMicrophone {}

package struct VoiceCallDevices: Sendable {
    let microphone: any VoiceCallMicrophone
    let speaker: any VoiceCallSpeaker

    package init(microphone: any VoiceCallMicrophone, speaker: any VoiceCallSpeaker) {
        self.microphone = microphone
        self.speaker = speaker
    }
}
