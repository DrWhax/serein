// Port of ts/components/conversation/WaveformScrubber.dom.tsx: the waveform as a slider.
// A click moves the play head to the clicked ratio (the first 2 of 47 bars rewind to 0);
// ↑/→ and ↓/← step 1 s, Page Up/Down 5 s (passed on as upstream does, see `onScrub`).

import SignalI18n
import SwiftUI

/// The playing message's audio state (upstream's `active` from the audioPlayer duck).
public struct AudioActive: Sendable, Equatable {
    public var playing: Bool
    public var currentTime: Double
    public var duration: Double
    public var playbackRate: Double
    public init(playing: Bool, currentTime: Double, duration: Double, playbackRate: Double) {
        self.playing = playing
        self.currentTime = currentTime
        self.duration = duration
        self.playbackRate = playbackRate
    }
}

/// The audioPlayer actions MessageAudio calls.
public struct AudioControls {
    /// Start this message's audio at a 0…1 position (when it is not the active one).
    public var playMessage: (Double) -> Void
    /// Move the active audio to a 0…1 position.
    public var setPosition: (Double) -> Void
    public var setIsPlaying: (Bool) -> Void
    public var setPlaybackRate: (Double) -> Void
    public init(playMessage: @escaping (Double) -> Void, setPosition: @escaping (Double) -> Void,
                setIsPlaying: @escaping (Bool) -> Void, setPlaybackRate: @escaping (Double) -> Void) {
        self.playMessage = playMessage
        self.setPosition = setPosition
        self.setIsPlaying = setIsPlaying
        self.setPlaybackRate = setPlaybackRate
    }
}

struct WaveformScrubber: View {
    static let rewindBarCount = 2
    static let smallIncrement = 1.0, bigIncrement = 5.0

    let peaks: [Double]
    let currentTime: Double
    let duration: Double?
    let barMinHeight: CGFloat
    let barMaxHeight: CGFloat
    let incoming: Bool
    let onClick: (Double) -> Void
    /// Upstream passes the new position as a ratio and MessageAudio treats it as seconds;
    /// kept as is.
    let onScrub: (Double) -> Void
    @Environment(\.i18n) var i18n

    static func progress(x: CGFloat, width: CGFloat, barCount: Int) -> Double {
        guard width > 0 else { return 0 }
        let p = Double(x / width)
        return p <= Double(rewindBarCount) / Double(barCount) ? 0 : p
    }

    func scrub(_ increment: Double) -> KeyPress.Result {
        guard let duration, duration > 0 else { return .ignored }
        onScrub(currentTime / duration + increment / duration)
        return .handled
    }

    var body: some View {
        AudioWaveformBars(peaks: peaks, barMinHeight: barMinHeight, barMaxHeight: barMaxHeight, currentTime: currentTime,
                          duration: duration ?? 1e-23, incoming: incoming)
            .contentShape(Rectangle())
            .background(GeometryReader { g in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in onClick(Self.progress(x: p.x, width: g.size.width, barCount: peaks.count)) }
            })
            .focusable()
            .onKeyPress(keys: [.upArrow, .rightArrow]) { _ in scrub(Self.smallIncrement) }
            .onKeyPress(keys: [.downArrow, .leftArrow]) { _ in scrub(-Self.smallIncrement) }
            .onKeyPress(keys: [.pageUp]) { _ in scrub(Self.bigIncrement) }
            .onKeyPress(keys: [.pageDown]) { _ in scrub(-Self.bigIncrement) }
            .accessibilityElement()
            .accessibilityLabel(i18n("icu:MessageAudio--slider"))
            .accessibilityValue(durationToPlaybackText(currentTime))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: _ = scrub(Self.smallIncrement)
                case .decrement: _ = scrub(-Self.smallIncrement)
                @unknown default: break
                }
            }
    }
}
