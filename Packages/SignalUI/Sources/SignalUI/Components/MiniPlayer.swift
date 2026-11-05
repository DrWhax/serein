// Port of ts/components/MiniPlayer.dom.tsx + PlaybackRateButton.dom.tsx (mini-player variant;
// stylesheets/components/MiniPlayer.scss, PlaybackRateButton.scss): the strip under the
// conversation header while a voice message plays — the mini play/pause button (a spinner
// while loading), "title · m:ss", the playback-rate button (scaled to nothing unless
// playing, but keeping its 38px slot) and Close. Upstream places it absolutely 52px below
// the top of the conversation (`shouldFlow`: in the flow).

import SignalI18n
import SwiftUI

public enum PlayerState: String, Sendable { case loading, playing, paused }

/// `PlaybackRateButton` (variant `mini-player`): "1×" … in body-2 bold 11px on a 38×18 chip.
public struct PlaybackRateButton: View {
    /// `playbackRates`, cycled by `nextPlaybackRate`.
    public static let rates: [Double] = [1, 1.5, 2, 0.5]
    public static func nextPlaybackRate(_ rate: Double) -> Double { rates[((rates.firstIndex(of: rate) ?? -1) + 1) % rates.count] }

    let playbackRate: Double
    let visible: Bool
    let onClick: () -> Void
    @Environment(\.i18n) var i18n

    public init(playbackRate: Double, visible: Bool = true, onClick: @escaping () -> Void) {
        self.playbackRate = playbackRate
        self.visible = visible
        self.onClick = onClick
    }

    var label: String {
        switch playbackRate {
        case 1.5: i18n("icu:MessageAudio--playbackRate1p5")
        case 2: i18n("icu:MessageAudio--playbackRate2")
        case 0.5: i18n("icu:MessageAudio--playbackRatep5")
        default: i18n("icu:MessageAudio--playbackRate1")
        }
    }

    public var body: some View {
        SwiftUI.Button(action: onClick) {
            CSSText(label + "×", style: LegacyType.inter(11, 18, -0.03, weight: 700), wrap: .nowrap, alignment: .center,
                    color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                .frame(width: 38, height: 18)
                .background(AxoColor(light: LegacyColor.blackAlpha08, dark: LegacyColor.whiteAlpha08), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .scaleEffect(visible ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: visible)
        .accessibilityLabel(label)
        .accessibilityHidden(!visible)
    }
}

public struct MiniPlayer: View {
    let title: String
    let state: PlayerState
    let currentTime: Double
    let duration: Double?
    let playbackRate: Double
    let onPlay: () -> Void
    let onPause: () -> Void
    let onPlaybackRate: (Double) -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(title: String, state: PlayerState, currentTime: Double, duration: Double?, playbackRate: Double,
                onPlay: @escaping () -> Void = {}, onPause: @escaping () -> Void = {}, onPlaybackRate: @escaping (Double) -> Void = { _ in },
                onClose: @escaping () -> Void = {}) {
        self.title = title
        self.state = state
        self.currentTime = currentTime
        self.duration = duration
        self.playbackRate = playbackRate
        self.onPlay = onPlay
        self.onPause = onPause
        self.onPlaybackRate = onPlaybackRate
        self.onClose = onClose
    }

    public var body: some View {
        let (mod, label): (PlaybackButton.Mod, String) = switch state {
        case .playing: (.pause, i18n("icu:MessageAudio--pause"))
        case .paused: (.play, i18n("icu:MessageAudio--play"))
        case .loading: (.computing, i18n("icu:MessageAudio--pending"))
        }
        var runs = [Emojify.run(title), .inlineBlock("·", CSSInlineBlock(paddingInline: 5))]
        if let duration { runs.append(CSSTextRun(durationToPlaybackText(state == .loading ? duration : currentTime))) }
        return HStack(spacing: 18) {
            PlaybackButton(mod: mod, variant: .mini, incoming: true, attachment: nil, label: label) {
                switch state {
                case .playing: onPause()
                case .paused: onPlay()
                case .loading: break
                }
            }
            .padding(.trailing, 12)          // .PlaybackButton margin-inline-end
            CSSText(runs: runs, style: LegacyType.body1(), wrap: .nowrap, color: .labelPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlaybackRateButton(playbackRate: playbackRate, visible: state == .playing) { onPlaybackRate(PlaybackRateButton.nextPlaybackRate(playbackRate)) }
            SwiftUI.Button(action: onClose) {
                SignalIcon("v3/x/x", size: 16, color: AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15), mask: true)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:close"))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray75))
    }
}
