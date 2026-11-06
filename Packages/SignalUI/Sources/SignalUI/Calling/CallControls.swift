// Shared calling chrome: CallBackgroundBlur.dom.tsx (the avatar, cover-scaled ×1.2 and
// blurred 25px, behind lobbies and video-off tiles), the CallControls bar (CallControls.scss:
// a gray-78 18px-radius bar, 480–640px, 80px tall: title and status, the round buttons, the
// join/leave button), CallingLobbyJoinButton.dom.tsx (as wide as its widest variant) and
// CallParticipantCount.dom.tsx.

import SignalI18n
import SwiftUI

public struct CallBackgroundBlur: View {
    let avatar: RGBAImage?
    let darken: Bool
    /// `.module-CallingLobby__local-preview--camera-is-off .module-calling__background--blur::before`
    let dim: Bool

    public init(avatar: RGBAImage?, darken: Bool = false, dim: Bool = false) {
        self.avatar = avatar
        self.darken = darken
        self.dim = dim
    }

    public var body: some View {
        ZStack {
            if let avatar {
                GeometryReader { g in
                    ZStack {
                        PixelImage(avatar, fit: .cover)
                        if dim { Color(.sRGB, white: 0, opacity: 0.4) }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .scaleEffect(1.2)
                    .blur(radius: 25)
                }
            }
            if darken { Color(rgba: RGBA(LegacyColor.gray60.r, LegacyColor.gray60.g, LegacyColor.gray60.b, 0.6)) }
        }
        .clipped()
    }
}

/// `CallParticipantCount`: "Group call" / "Call link" / "N people" (a button opening the
/// participants list once someone is in the call, with a chevron).
public struct CallParticipantCount: View {
    let isAdhoc: Bool
    let isAdhocJoinRequestPending: Bool
    let participantCount: Int
    let toggleParticipants: () -> Void
    @Environment(\.i18n) var i18n

    public init(isAdhoc: Bool, isAdhocJoinRequestPending: Bool = false, participantCount: Int, toggleParticipants: @escaping () -> Void) {
        self.isAdhoc = isAdhoc
        self.isAdhocJoinRequestPending = isAdhocJoinRequestPending
        self.participantCount = participantCount
        self.toggleParticipants = toggleParticipants
    }

    var text: String {
        if isAdhoc {
            if isAdhocJoinRequestPending { return i18n("icu:CallControls__InfoDisplay--adhoc-join-request-pending") }
            if participantCount == 0 { return i18n("icu:CallControls__InfoDisplay--adhoc-call") }
        } else if participantCount == 0 {
            return i18n("icu:CallControls__InfoDisplay--group-call")
        }
        return i18n("icu:CallControls__InfoDisplay--participants", ["count": .number(Double(max(participantCount, 1)))])
    }

    public var body: some View {
        let gray20 = AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20)
        let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18)
        if participantCount > 0 || isAdhoc {
            Button(action: toggleParticipants) {
                HStack(spacing: 1) {
                    CSSText(text, style: style, wrap: .nowrap, color: gray20)
                    SignalIcon("v3/chevron/chevron-right", size: 14, color: gray20, mask: true).frame(width: 14, height: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(UndimmedButtonStyle())
            .accessibilityLabel(i18n("icu:calling__participants--pluralized", ["people": .number(Double(max(participantCount, 1)))]))
        } else {
            CSSText(text, style: style, wrap: .nowrap, color: gray20)
        }
    }
}

/// `CallingLobbyJoinButtonVariant`
public enum CallingLobbyJoinButtonVariant: CaseIterable, Sendable { case callIsFull, join, loading, start, askToJoin }

public struct CallingLobbyJoinButton: View {
    let variant: CallingLobbyJoinButtonVariant
    let disabled: Bool
    let onClick: () -> Void
    @Environment(\.i18n) var i18n

    public init(variant: CallingLobbyJoinButtonVariant, disabled: Bool = false, onClick: @escaping () -> Void) {
        self.variant = variant
        self.disabled = disabled
        self.onClick = onClick
    }

    static let textStyle = CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 12, lineHeight: 17, letterSpacing: -0.08)

    func label(_ v: CallingLobbyJoinButtonVariant) -> String? {
        switch v {
        case .callIsFull: i18n("icu:CallingLobbyJoinButton--call-full")
        case .join: i18n("icu:CallingLobbyJoinButton--join")
        case .start: i18n("icu:CallingLobbyJoinButton--start")
        case .askToJoin: i18n("icu:CallingLobbyJoinButton--ask-to-join")
        case .loading: nil
        }
    }

    /// The widest variant (16px padding each side), rounded up; 31px tall.
    var width: CGFloat {
        let widest = CallingLobbyJoinButtonVariant.allCases.compactMap(label)
            .map { CSSTextLayout.make($0, Self.textStyle, wrap: .nowrap, maxWidth: nil).width }.max() ?? 0
        return (widest + 32).rounded(.up)
    }

    public var body: some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        Button(action: onClick) {
            ZStack {
                if let text = label(variant) {
                    CSSText(text, style: Self.textStyle, wrap: .nowrap, color: white)
                } else {
                    // <Spinner size="18px" svgSize="small" /> (margin-block −5px)
                    Spinner(svgSize: .small, size: 18)
                }
            }
            .frame(width: width, height: 31)
            .background(Capsule().fill(AxoColor.fillAffirmative))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(disabled)
    }
}

/// The CallControls bar between its two 122.67px outer spacers (the local preview's width).
public struct CallControlsBar<Buttons: View, Action: View>: View {
    let title: String
    let status: AnyView?
    let buttons: Buttons
    let action: Action

    public init(title: String, status: AnyView?, @ViewBuilder buttons: () -> Buttons, @ViewBuilder action: () -> Action) {
        self.title = title
        self.status = status
        self.buttons = buttons()
        self.action = action()
    }

    public var body: some View {
        let gray15 = AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                CSSText(title, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 700), size: 14, lineHeight: 20), wrap: .clamp(2), color: gray15)
                if let status { status.frame(minHeight: 18, alignment: .leading) } else { Color.clear.frame(height: 18) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) { buttons }
            HStack(spacing: 0) { Spacer(minLength: 0); action }
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .frame(height: 80)
        .frame(minWidth: 480, maxWidth: 640)
        .background {
            RoundedRectangle(cornerRadius: 18).fill(Color(rgba: LegacyColor.gray78))
                .shadow(color: Color(.sRGB, white: 0, opacity: 0.4), radius: 7, x: 0, y: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
