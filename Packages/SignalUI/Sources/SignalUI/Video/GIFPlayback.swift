// When GIF-flagged videos play (ts/components/conversation/GIF.dom.tsx): only while the
// window has focus, and with tap-to-play (reduced motion) only until MAX_GIF_TIME seconds or
// MAX_GIF_REPEAT loops since the last tap (none before the first tap).

public struct GIFPlayback: Sendable, Equatable {
    public static let maxRepeat = 4
    public static let maxTime = 8.0

    /// Loop count of the engine when the user last tapped (nil: never).
    public var tappedAtLoop: Int?

    public init(tappedAtLoop: Int? = nil) { self.tappedAtLoop = tappedAtLoop }

    /// `isFocused && !isTapToPlayPaused`, with upstream's playTime (whole loops since the
    /// tap × duration; MAX_GIF_TIME before any tap) and repeatCount.
    public func shouldPlay(tapToPlay: Bool, focused: Bool, loopCount: Int, currentTime: Double, duration: Double) -> Bool {
        guard focused else { return false }
        guard tapToPlay else { return true }
        guard let tap = tappedAtLoop else { return false }
        let repeats = max(0, loopCount - tap)
        let playTime = Double(repeats) * duration
        return playTime + currentTime < Self.maxTime && repeats < Self.maxRepeat
    }
}

extension VideoPlaybackEngine {
    /// Starts or pauses to match `shouldPlay`.
    public func match(_ shouldPlay: Bool) async {
        if shouldPlay { await play() } else { pause() }
    }
}
