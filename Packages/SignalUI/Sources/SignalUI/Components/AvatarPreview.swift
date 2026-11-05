// Port of ts/components/AvatarPreview.dom.tsx (stylesheets/components/AvatarPreview.scss): the
// 80px avatar of the avatar editors and group settings: the image (with a clear badge), a
// placeholder gradient, the spinner while a new value loads, or the colour with initials or
// the person / group / note icon at 70%; with the camera badge when an upload is offered.

import SignalI18n
import SwiftUI

public struct AvatarPreview: View {
    let avatarColor: String
    /// `avatarValue`: the new avatar's decoded pixels (nil while it is being decoded and
    /// `valuePending`).
    let avatarValue: RGBAImage?
    let valuePending: Bool
    /// A preset avatar as the value (upstream renders it to bytes with avatarDataToBytes).
    let avatarData: AvatarData?
    /// `avatarUrl`: the current avatar, decoded.
    let avatarImage: RGBAImage?
    let placeholderGradient: (start: RGBA, end: RGBA)?
    let hasAvatar: Bool
    let conversationTitle: String?
    let isGroup: Bool
    let noteToSelf: Bool
    let showUploadButton: Bool
    let size: CGFloat
    /// The initials' size (`font-size` on the avatar; 32px, the AvatarLightbox's 16em = 224px).
    var initialsFontSize: CGFloat = 32

    /// The avatar with its initials at `size` (AvatarLightbox's `font-size: 16em`).
    public func initialsFontSize(_ size: CGFloat) -> AvatarPreview {
        var copy = self
        copy.initialsFontSize = size
        return copy
    }
    /// The 4px / 16px block margins (callers' `style` can zero them).
    let margins: Bool
    /// Takes the dialog's initial focus (the first focusable control), showing its ring.
    let autoFocus: Bool
    let onClear: (() -> Void)?
    let onClick: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(avatarColor: String? = nil, avatarValue: RGBAImage? = nil, valuePending: Bool = false, avatarData: AvatarData? = nil, avatarImage: RGBAImage? = nil,
                placeholderGradient: (start: RGBA, end: RGBA)? = nil, hasAvatar: Bool = false, conversationTitle: String? = nil,
                isGroup: Bool = false, noteToSelf: Bool = false, showUploadButton: Bool = false, size: CGFloat = 80, margins: Bool = true, autoFocus: Bool = false,
                onClear: (() -> Void)? = nil, onClick: (() -> Void)? = nil) {
        self.avatarColor = avatarColor ?? AxoTokens.Avatar.allColorNames[0]
        self.avatarValue = avatarValue
        self.valuePending = valuePending
        self.avatarData = avatarData
        self.avatarImage = avatarImage
        self.placeholderGradient = placeholderGradient
        self.hasAvatar = hasAvatar
        self.conversationTitle = conversationTitle
        self.isGroup = isGroup
        self.noteToSelf = noteToSelf
        self.showUploadButton = showUploadButton
        self.size = size
        self.margins = margins
        self.autoFocus = autoFocus
        self.onClear = onClear
        self.onClick = onClick
    }

    enum Status { case loading, nothing, image(RGBAImage), data(AvatarData), placeholder }

    var status: Status {
        if valuePending { return .loading }
        if noteToSelf { return .nothing }
        if let avatarValue { return .image(avatarValue) }
        if let avatarData { return .data(avatarData) }
        if let avatarImage { return .image(avatarImage) }
        if hasAvatar && placeholderGradient != nil { return .placeholder }
        return .nothing
    }

    /// 0 4px 16px black/12%, 0 2px 4px black/20%
    static let badgeShadow = [AxoShadowLayer(inset: false, x: 0, y: 4, blur: 16, spread: 0, color: RGBA(0, 0, 0, 0.12)),
                              AxoShadowLayer(inset: false, x: 0, y: 2, blur: 4, spread: 0, color: RGBA(0, 0, 0, 0.2))]

    @ViewBuilder var avatar: some View {
        let colors = AxoTokens.Avatar.colorValues(avatarColor)
        switch status {
        case .nothing:
            ZStack {
                Circle().fill(AxoColor(colors.bg))
                let fg = AxoColor(colors.fg)
                if isGroup {
                    SignalIcon("v3/group/group", size: size * 0.7, color: fg, mask: true)
                } else if noteToSelf {
                    SignalIcon("v3/note/note", size: size * 0.7, color: fg, mask: true)
                } else if let initials = Avatar.initials(conversationTitle ?? "") {
                    CSSText(initials, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: initialsFontSize,
                                                         lineHeight: (initialsFontSize * 1.21).rounded()), wrap: .nowrap, color: fg)
                } else {
                    SignalIcon("v3/person/person", size: size * 0.7, color: fg, mask: true)
                }
            }
        case .placeholder:
            let g = placeholderGradient ?? AxoTokens.Avatar.gradient(hash: 0)
            Circle().fill(LinearGradient(colors: [g.start.color, g.end.color], startPoint: .top, endPoint: .bottom))
        case .loading:
            ZStack {
                Circle().fill(AxoColor(LegacyColor.black))
                Spinner(svgSize: .normal, direction: .onAvatar, size: 70)
            }
        case .image(let image):
            PixelImage(image, fit: .cover).clipShape(Circle())
        case .data(let data):
            AvatarDataImage(data: data, size: size).clipShape(Circle())
        }
    }

    var hasImage: Bool {
        switch status {
        case .image, .data: true
        default: false
        }
    }

    public var body: some View {
        avatar
            .frame(width: size, height: size)
            .axoFocusRing(autoFocus && staticRendering, in: Circle())
            .overlay(alignment: .topTrailing) {
                if hasImage, let onClear {
                    SwiftUI.Button(action: onClear) {
                        SignalIcon("v3/x/x-compact", size: 16, color: AxoColor(LegacyColor.gray75))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AxoColor(LegacyColor.white)))
                            .cssBoxShadow(Self.badgeShadow, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:delete"))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showUploadButton {
                    SignalIcon("v3/camera/camera", size: 16, color: AxoColor(LegacyColor.black))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(AxoColor(LegacyColor.gray02)))
                        .cssBoxShadow(Self.badgeShadow, in: Circle())
                        .offset(x: 7, y: -4)
                }
            }
            .contentShape(Circle())
            .onTapGesture { onClick?() }
            .accessibilityAddTraits(onClick != nil ? .isButton : [])
            .padding(.top, margins ? 4 : 0).padding(.bottom, margins ? 16 : 0)
            .frame(maxWidth: .infinity)
    }
}
