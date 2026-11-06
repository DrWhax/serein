// Port of ts/components/CallingButton.dom.tsx + stylesheets/components/CallingButton.scss:
// the round 36px call control (icon 20px, painted with color-svg) in a container with 10px
// inline margins, its tooltip (dark) naming what a click does.

import SignalI18n
import SwiftUI

public enum CallingButtonType: String, CaseIterable, Sendable {
    case audioDisabled = "AUDIO_DISABLED", audioOff = "AUDIO_OFF", audioOn = "AUDIO_ON", fullScreenCall = "FULL_SCREEN_CALL"
    case hangupGroup = "HANGUP_GROUP", hangupDirect = "HANGUP_DIRECT", maximize = "MAXIMIZE", minimize = "MINIMIZE", moreOptions = "MORE_OPTIONS"
    case presentingDisabled = "PRESENTING_DISABLED", presentingOff = "PRESENTING_OFF", presentingOn = "PRESENTING_ON"
    case raiseHandOff = "RAISE_HAND_OFF", raiseHandOn = "RAISE_HAND_ON", reactOff = "REACT_OFF", reactOn = "REACT_ON"
    case ringDisabled = "RING_DISABLED", ringOff = "RING_OFF", ringOn = "RING_ON"
    case videoDisabled = "VIDEO_DISABLED", videoOff = "VIDEO_OFF", videoOn = "VIDEO_ON"

    enum Look { case regular, highlighted, disabled, custom(background: RGBA, icon: RGBA) }

    /// (icon, look, tooltip key, disabled)
    var spec: (icon: String, look: Look, tooltip: String?, disabled: Bool) {
        let micSlash = "v3/mic/mic-slash-fill-light", videoSlash = "v3/video/video-slash-fill-light"
        let hand = "v3/raise_hand/raise_hand-fill-light", heart = "v3/heart/heart-plus-fill", bellSlash = "v3/bell/bell-slash-fill"
        let share = "v3/share_screen/share_screen-fill-light"
        let overlay = RGBA(LegacyColor.gray80.r, LegacyColor.gray80.g, LegacyColor.gray80.b, 0.7)
        return switch self {
        case .audioDisabled: (micSlash, .disabled, "icu:calling__button--audio-disabled", true)
        case .audioOff: (micSlash, .highlighted, "icu:calling__button--audio-on", false)
        case .audioOn: ("v3/mic/mic-fill-light", .regular, "icu:calling__button--audio-off", false)
        case .videoDisabled: (videoSlash, .disabled, "icu:calling__button--video-disabled", true)
        case .videoOff: (videoSlash, .highlighted, "icu:calling__button--video-on", false)
        case .videoOn: ("v3/video/video-fill-light", .regular, "icu:calling__button--video-off", false)
        case .ringDisabled: (bellSlash, .disabled, "icu:calling__button--ring__disabled-because-group-is-too-large", true)
        case .ringOff: (bellSlash, .highlighted, "icu:CallingButton--ring-on", false)
        case .ringOn: ("v3/bell/bell-ring-fill-light", .regular, "icu:CallingButton__ring-off", false)
        case .reactOff: (heart, .regular, "icu:calling__button--react", false)
        case .reactOn: (heart, .highlighted, nil, false)
        case .raiseHandOff: (hand, .regular, "icu:CallControls__MenuItemRaiseHand", false)
        case .raiseHandOn: (hand, .highlighted, "icu:CallControls__MenuItemRaiseHand--lower", false)
        case .presentingDisabled: (share, .disabled, "icu:calling__button--presenting-disabled", true)
        case .presentingOn: (share, .highlighted, "icu:calling__button--presenting-off", false)
        case .presentingOff: (share, .regular, "icu:calling__button--presenting-on", false)
        case .moreOptions: ("v3/more/more", .regular, "icu:CallingButton--more-options", false)
        case .maximize: ("v3/maximize/maximize", .custom(background: overlay, icon: LegacyColor.white), "icu:calling__preview--maximize", false)
        case .minimize: ("v3/minimize/minimize", .custom(background: overlay, icon: LegacyColor.white), "icu:calling__preview--minimize", false)
        case .fullScreenCall: ("v3/pip/pip-maximize-light", .custom(background: LegacyColor.gray80, icon: LegacyColor.gray15), "icu:calling__pip--off", false)
        case .hangupDirect: ("v3/phone/phone-down-fill-light", .custom(background: LegacyColor.accentRed, icon: LegacyColor.white),
                             "icu:CallControls__JoinLeaveButton--hangup-1-1-tooltip", false)
        case .hangupGroup: ("v3/phone/phone-down-fill-light", .custom(background: LegacyColor.accentRed, icon: LegacyColor.white),
                            "icu:CallControls__JoinLeaveButton--hangup-group-tooltip", false)
        }
    }
}

public struct CallingButton: View {
    /// `.CallingButton__Button--self-view-normal`: 28px with a 16px icon, no margins.
    /// `.pip`: the PiP's 32px controls; `.pipUnpin`: 36px; neither has margins there.
    public enum Size: Sendable { case regular, selfView, pip, pipUnpin }

    let buttonType: CallingButtonType
    let isVisible: Bool
    let tooltipDirection: TooltipPlacement
    let size: Size
    let onClick: () -> Void
    let onHover: ((Bool) -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(_ buttonType: CallingButtonType, isVisible: Bool = true, tooltipDirection: TooltipPlacement = .top, size: Size = .regular,
                onHover: ((Bool) -> Void)? = nil, onClick: @escaping () -> Void) {
        self.buttonType = buttonType
        self.isVisible = isVisible
        self.tooltipDirection = tooltipDirection
        self.size = size
        self.onHover = onHover
        self.onClick = onClick
    }

    var colors: (background: RGBA, icon: RGBA, opacity: Double, blur: Bool) {
        switch buttonType.spec.look {
        case .regular: (LegacyColor.gray60, LegacyColor.gray15, 1, true)
        case .highlighted: (LegacyColor.gray15, LegacyColor.gray90, 1, false)
        case .disabled: (LegacyColor.gray60, LegacyColor.gray15, 0.4, false)
        case .custom(let b, let i): (b, i, 1, false)
        }
    }

    var button: some View {
        let spec = buttonType.spec, c = colors
        // Self view: 28px with a 16px icon; PiP controls: 32px (`.module-calling-pip__actions .CallingButton__icon`).
        let box: CGFloat = size == .selfView ? 28 : (size == .pip ? 32 : 36), icon: CGFloat = size == .selfView ? 16 : 20
        return Button(action: onClick) {
            SignalIcon(spec.icon, size: icon, color: AxoColor(light: c.icon, dark: c.icon), mask: true)
                .frame(width: box, height: box)
                .background {
                    ZStack {
                        // backdrop-filter: blur(10px) (over call video; nothing to blur when rendered statically)
                        if c.blur && !staticRendering { Circle().fill(.ultraThinMaterial) }
                        Circle().fill(Color(rgba: c.background))
                    }
                }
                .contentShape(Circle())
                .compositingGroup()      // CSS opacity fades the element as one layer
                .opacity(c.opacity)
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(spec.disabled)
        .accessibilityLabel(spec.tooltip.map { i18n($0) } ?? "")
        .onHover { onHover?($0) }
    }

    public var body: some View {
        let margin: CGFloat = size == .regular ? 10 : 0
        Group {
            if let key = buttonType.spec.tooltip {
                Tooltip(i18n(key), direction: tooltipDirection, forceDark: true) { button }
            } else {
                button
            }
        }
        // inline-flex, max-width 64px: as wide as the 36px button.
        .padding(.horizontal, margin)
        .padding(.leading, isVisible ? 0 : -100)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.3), value: isVisible)
    }
}

extension Color {
    init(rgba c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

/// A plain style without SwiftUI's own dimming of disabled buttons (the CSS draws that).
struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
