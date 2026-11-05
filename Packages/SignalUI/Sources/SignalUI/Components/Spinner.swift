// Port of ts/components/Spinner.dom.tsx (deprecated upstream in favour of SpinnerV2) and its
// `.module-spinner__*` rules in stylesheets/_modules.scss: a track ring and a quarter arc,
// both SVG masks (spinner-track-56 / spinner-56, or the -24 files for `small`) stretched to
// the container, the arc rotating once a second (at rest with animations disabled).

import SwiftUI

public struct Spinner: View {
    public enum SvgSize: String, Sendable, Hashable, CaseIterable { case small, normal }

    public enum Direction: String, Sendable, Hashable, CaseIterable {
        case outgoing, incoming
        case onBackground = "on-background"
        case onPrimaryButton = "on-primary-button"
        case onProgressDialog = "on-progress-dialog"
        case onAvatar = "on-avatar"
    }

    let svgSize: SvgSize
    let direction: Direction?
    /// CSS `size` (height and width); nil = the container's 56px (24px small).
    let size: CGFloat?
    let ariaLabel: String?
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    /// Colour overrides for callers that restyle `.module-spinner__circle` / `__arc`.
    var circleColor: AxoColor?
    var arcColor: AxoColor?

    public init(svgSize: SvgSize, direction: Direction? = nil, size: CGFloat? = nil, ariaLabel: String? = nil,
                circleColor: AxoColor? = nil, arcColor: AxoColor? = nil) {
        self.circleColor = circleColor
        self.arcColor = arcColor
        self.svgSize = svgSize
        self.direction = direction
        self.size = size
        self.ariaLabel = ariaLabel
    }

    var colors: (circle: AxoColor, arc: AxoColor) {
        let alpha40 = AxoColor(LegacyColor.whiteAlpha40)
        let defaultArc = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05)
        switch direction {
        case nil: return (alpha40, defaultArc)
        case .incoming: return (alpha40, AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray02))
        case .outgoing: return (alpha40, AxoColor(light: LegacyColor.white, dark: LegacyColor.gray05))
        case .onAvatar, .onPrimaryButton: return (alpha40, AxoColor(LegacyColor.white))
        case .onBackground: return (AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75), AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
        case .onProgressDialog: return (AxoColor(light: LegacyColor.white, dark: LegacyColor.gray80), AxoColor(LegacyColor.ultramarine))
        }
    }

    public var body: some View {
        let side = size ?? (svgSize == .small ? 24 : 56)
        let (defaultCircle, defaultArc) = colors
        let circle = circleColor ?? defaultCircle, arc = arcColor ?? defaultArc
        ZStack {
            LegacyIcon.Mask(svgSize == .small ? .spinnerTrack24 : .spinnerTrack56, color: circle)
            if animationsDisabled {
                LegacyIcon.Mask(svgSize == .small ? .spinner24 : .spinner56, color: arc)
            } else {
                TimelineView(.animation) { timeline in
                    LegacyIcon.Mask(svgSize == .small ? .spinner24 : .spinner56, color: arc)
                        .rotationEffect(.degrees(360 * timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)))
                }
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)                      // margin-inline: auto
        .accessibilityElement()
        .accessibilityLabel(ariaLabel ?? "")
    }
}
