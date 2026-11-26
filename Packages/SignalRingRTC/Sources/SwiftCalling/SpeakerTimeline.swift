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
