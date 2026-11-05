// Port of ts/components/CompositionRecordingDraft.dom.tsx (stylesheets/components/
// CompositionRecordingDraft.scss): a recorded voice note waiting to be sent — in the
// RecordingComposer pill, the draft play/pause button and a waveform scrubber filling the
// rest (`__sizer`: flex 1, basis 0), one 2px bar every 4px (`floor(width / 4)` bars, 2…20px
// tall). Upstream computes the peaks from the audio (useComputePeaks); here the caller passes
// them (the voice-note pipeline decodes the recording).

import SignalI18n
import SwiftUI

public struct CompositionRecordingDraft: View {
    /// Playback state while the draft plays (`active`).
    public struct Active: Sendable, Hashable {
        public var playing: Bool
        public var duration: Double?
        public var currentTime: Double
        public init(playing: Bool, duration: Double?, currentTime: Double) {
            self.playing = playing
            self.duration = duration
            self.currentTime = currentTime
        }
    }

    let peaks: [Double]
    let duration: Double
    let active: Active?
    let onCancel: () -> Void
    let onSend: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onScrub: (Double) -> Void
    @Environment(\.i18n) var i18n

    public init(peaks: [Double], duration: Double, active: Active? = nil, onCancel: @escaping () -> Void = {}, onSend: @escaping () -> Void = {},
                onPlay: @escaping () -> Void = {}, onPause: @escaping () -> Void = {}, onScrub: @escaping (Double) -> Void = { _ in }) {
        self.peaks = peaks
        self.duration = duration
        self.active = active
        self.onCancel = onCancel
        self.onSend = onSend
        self.onPlay = onPlay
        self.onPause = onPause
        self.onScrub = onScrub
    }

    /// The peaks for `count` bars (nearest sample when the widths differ).
    static func bars(_ peaks: [Double], count: Int) -> [Double] {
        guard count > 0, !peaks.isEmpty else { return [] }
        if peaks.count == count { return peaks }
        return (0..<count).map { peaks[min(peaks.count - 1, $0 * peaks.count / count)] }
    }

    public var body: some View {
        let playing = active?.playing ?? false
        RecordingComposer(onCancel: onCancel, onSend: onSend) {
            PlaybackButton(mod: playing ? .pause : .play, variant: .draft, incoming: true, attachment: nil,
                           label: i18n(playing ? "icu:MessageAudio--pause" : "icu:MessageAudio--play")) { playing ? onPause() : onPlay() }
                .padding(.trailing, 12)
            GeometryReader { geo in
                let count = Int((geo.size.width / 4).rounded(.down))
                AudioWaveformBars(peaks: Self.bars(peaks, count: count), barMinHeight: 2, barMaxHeight: 20,
                                  currentTime: active?.currentTime ?? 0, duration: active?.duration ?? duration, incoming: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { location in onScrub(min(1, max(0, location.x / max(1, geo.size.width)))) }
            }
            .accessibilityElement()
            .accessibilityLabel(i18n("icu:MessageAudio--slider"))
        }
    }
}
