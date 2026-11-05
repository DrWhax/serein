// Port of ts/components/conversation/MessageAudio.dom.tsx (with PlaybackButton, WaveformScrubber /
// Waveform and useComputePeaks): an audio attachment's play button, its 47-bar waveform, the
// countdown (or size until downloaded), the unplayed dot and the metadata.
// stylesheets/components/MessageAudio.scss, PlaybackButton.scss, Waveform.scss.

import SignalI18n
import SwiftUI

/// `durationToPlaybackText`: m:ss, or h:mm:ss from an hour.
func durationToPlaybackText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
    return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
}

/// `waveformToPeaks`: the 0…255 waveform averaged into `barCount` 0…1 peaks.
func waveformToPeaks(_ waveform: [Int], barCount: Int) -> [Double] {
    let stride = Double(waveform.count) / Double(barCount)
    return (0..<barCount).map { i in
        var mean = 0.0, count = 0.0
        var j = Int((Double(i) * stride).rounded())
        while Double(j) < min(Double(i + 1) * stride, Double(waveform.count)) {
            mean += Double(waveform[j]) / 255
            count += 1
            j += 1
        }
        return mean / (count + 1e-23)
    }
}

/// An audio attachment's decoded waveform (`computeWaveform`: 0…255 RMS levels) and duration.
public struct AudioWaveform: Sendable, Hashable {
    public var waveform: [Int]
    public var duration: Double
    public init(waveform: [Int], duration: Double) {
        self.waveform = waveform
        self.duration = duration
    }
}

/// `PlaybackButton` (ts/components/PlaybackButton.dom.tsx): a button of `variant` size (message
/// 36, draft 18, mini 14) with a play / pause / download / cancel glyph (20px; 10px in draft,
/// 16px in mini), or a spinner while downloading or computing. Only the message variant has
/// a background (white 80% / 20% incoming, white 20% outgoing).
struct PlaybackButton: View {
    enum Mod { case play, pause, notDownloaded, downloading, computing }
    enum Variant { case message, mini, draft }
    let mod: Mod
    var variant: Variant = .message
    /// `context`: incoming (or none) draws label-primary glyphs, outgoing primary-oncolor.
    let incoming: Bool
    let attachment: MessageAttachment?
    let label: String
    let action: () -> Void

    var size: CGFloat { switch variant { case .message: 36; case .mini: 14; case .draft: 18 } }
    var glyph: CGFloat { switch variant { case .message: 20; case .mini: 16; case .draft: 10 } }

    var body: some View {
        SwiftUI.Button(action: action) {
            ZStack {
                if variant == .message {
                    Circle().fill(incoming ? AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha20) : AxoColor(LegacyColor.whiteAlpha20))
                }
                switch mod {
                case .computing, .downloading:
                    let total = Double(attachment?.size ?? 0), done = Double(attachment?.totalDownloaded ?? 0)
                    SpinnerV2(value: total > 0 && done > 0 ? done : nil, min: 0, max: total > 0 ? total : 1,
                              variant: incoming ? .noBackgroundIncoming : .noBackground, size: size, strokeWidth: variant == .message ? 2 : 1)
                    if mod == .downloading { icon("v3/x/x-bold") }
                case .play: icon("v3/play/play-fill")
                case .pause: icon("v3/pause/pause-fill")
                case .notDownloaded: icon("v3/arrow/arrow-down")
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    func icon(_ name: String) -> some View {
        SignalIcon(name, size: glyph, color: incoming ? .labelPrimary : .labelPrimaryOncolor)
            .frame(width: glyph, height: glyph)
            .frame(width: size, height: size)
    }
}

/// `Waveform`: 2px bars 2px apart, each max(min, max × peak); played bars are darker and the
/// one at the play head is full height.
struct AudioWaveformBars: View {
    let peaks: [Double]
    let barMinHeight: CGFloat
    let barMaxHeight: CGFloat
    let currentTime: Double
    let duration: Double
    let incoming: Bool

    var body: some View {
        let peakPosition = Double(peaks.count) * (currentTime / (duration == 0 ? 1e-23 : duration))
        let base = incoming ? AxoColor(light: LegacyColor.blackAlpha40, dark: LegacyColor.whiteAlpha40) : AxoColor(LegacyColor.whiteAlpha40)
        let active = incoming ? AxoColor(light: LegacyColor.blackAlpha80, dark: LegacyColor.whiteAlpha70) : AxoColor(LegacyColor.whiteAlpha80)
        HStack(alignment: .center, spacing: 2) {
            ForEach(peaks.indices, id: \.self) { i in
                let highlight = Double(i) < peakPosition
                let height = highlight && Double(i + 1) >= peakPosition ? barMaxHeight : max(barMinHeight, barMaxHeight * peaks[i])
                RoundedRectangle(cornerRadius: 1).fill(highlight ? active : base).frame(width: 2, height: height)
            }
        }
        .fixedSize()
    }
}

struct MessageAudio: View {
    let attachment: MessageAttachment
    let waveform: AudioWaveform?
    let direction: MessageDirection
    let played: Bool
    let withContentAbove: Bool
    let withContentBelow: Bool
    let metadata: MessageMetadata?
    let onPlay: (() -> Void)?
    let kickOffDownload: (() -> Void)?
    let cancelDownload: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme

    static let barCount = 47

    enum State { case pending, notDownloaded, computing, normal }
    var state: State {
        if attachment.pending { return .pending }
        if !attachment.isDownloaded { return .notDownloaded }
        if waveform == nil { return .computing }
        return .normal
    }

    var body: some View {
        let incoming = direction == .incoming
        let state = self.state
        let duration = waveform.map { max($0.duration, 1e-23) } ?? 1e-23
        let peaks = waveform.map { waveformToPeaks($0.waveform, barCount: Self.barCount) } ?? Array(repeating: 0, count: Self.barCount)
        let mod: PlaybackButton.Mod
        let label: String
        switch state {
        case .computing: (mod, label) = (.computing, i18n("icu:MessageAudio--pending"))
        case .pending: (mod, label) = (.downloading, i18n("icu:MessageAudio--pending"))
        case .notDownloaded: (mod, label) = (.notDownloaded, i18n("icu:MessageAudio--download"))
        case .normal: (mod, label) = (.play, i18n("icu:MessageAudio--play"))
        }
        let countdown = state == .notDownloaded || state == .pending || duration < 1 ? formatFileSize(attachment.size) : durationToPlaybackText(duration)
        let separator = incoming ? AxoColor(light: LegacyColor.blackAlpha20, dark: LegacyColor.whiteAlpha20) : AxoColor(LegacyColor.whiteAlpha20)
        return VStack(alignment: .leading, spacing: 0) {
            // __button-and-waveform: row, centred, 5px below
            HStack(alignment: .center, spacing: 0) {
                PlaybackButton(mod: mod, incoming: incoming, attachment: attachment, label: label) {
                    switch state {
                    case .pending: cancelDownload?()
                    case .notDownloaded: kickOffDownload?()
                    case .normal: onPlay?()
                    case .computing: break
                    }
                }
                .padding(.trailing, 12)
                AudioWaveformBars(peaks: peaks, barMinHeight: state == .normal ? 4 : 2, barMaxHeight: 20, currentTime: 0, duration: duration,
                                  incoming: incoming)
                    .accessibilityElement()
                    .accessibilityLabel(i18n("icu:MessageAudio--slider"))
                    .accessibilityValue(durationToPlaybackText(0))
            }
            .padding(.bottom, 5)
            // __metadata: the countdown, the unplayed dot, and the message metadata
            HStack(alignment: .center, spacing: 0) {
                CSSText(countdown, style: LegacyType.caption(), wrap: .nowrap, alignment: .center,
                        color: incoming ? AxoColor(light: LegacyColor.blackAlpha60, dark: LegacyColor.whiteAlpha80) : AxoColor(LegacyColor.whiteAlpha80))
                    .fixedSize()
                    .frame(width: 36)
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    if !played {
                        Circle().fill(incoming ? AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) : AxoColor(LegacyColor.whiteAlpha80))
                            .frame(width: 6, height: 6)
                            .frame(width: 14, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                // .module-message__metadata keeps its 3px margin-top (the row centres on 17px).
                if let metadata, !withContentBelow { metadata.padding(.top, 3) }
            }
        }
        .padding(.top, withContentAbove ? 6 : 2)
        // --with-content-below: 12px padding, a 1px border (the separator from the text), 7px margin
        .padding(.bottom, withContentBelow ? 12 + 1 : 0)
        .overlay(alignment: .bottom) { if withContentBelow { Rectangle().fill(separator).frame(height: 1) } }
        .padding(.bottom, withContentBelow ? 7 : 0)
        .environment(\.layoutDirection, .leftToRight)
    }
}
