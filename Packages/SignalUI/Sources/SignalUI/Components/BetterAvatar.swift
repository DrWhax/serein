// Ports of ts/components/BetterAvatarBubble.dom.tsx (stylesheets/components/BetterAvatarBubble.scss)
// and BetterAvatar.dom.tsx, with the drawing of ts/util/avatarDataToBytes.dom.ts: a preset
// avatar (colour + text, colour + icon, or an image) in a selectable 2px-ringed bubble.
//
// Upstream draws the avatar on a 1024px canvas and shows it as a background image scaled to
// `size`; here the same drawing is a view (the icons are vector paths from images/avatars).

import SignalI18n
import SwiftUI

/// `PersonalAvatarIcons` / `GroupAvatarIcons` (ts/types/Avatar.std.ts)
public enum AvatarIcons {
    public static let personal = ["abstract_01", "abstract_02", "abstract_03", "cat", "dog", "fox", "tucan", "pig", "dinosour", "sloth",
                                  "incognito", "ghost"]
    public static let group = ["balloon", "book", "briefcase", "celebration", "drink", "football", "heart", "house", "melon", "soccerball",
                               "sunset", "surfboard"]
}

/// `AvatarDataType`
public struct AvatarData: Identifiable, Sendable {
    public var id: String
    public var color: String?
    public var icon: String?
    public var text: String?
    public var image: RGBAImage?
    public init(id: String, color: String? = nil, icon: String? = nil, text: String? = nil, image: RGBAImage? = nil) {
        self.id = id
        self.color = color
        self.icon = icon
        self.text = text
        self.image = image
    }
}

/// `avatarDataToBytes`, drawn at `size`: the image; or the colour's background with the text
/// (Inter, fitted to 75% of the canvas, centred 30/1024 below the middle); or the icon over it.
public struct AvatarDataImage: View {
    let data: AvatarData
    let size: CGFloat
    public init(data: AvatarData, size: CGFloat) {
        self.data = data
        self.size = size
    }

    static let canvas: CGFloat = 1024

    /// `getFittedFontSize(1024, text)` with Inter's ink bounds.
    static func fittedFontSize(_ text: String) -> CGFloat {
        let diameter = (canvas * 0.75).rounded(.up)
        var candidate = (canvas * (text.count == 1 && text.first.map(CSSTextLayout.isEmoji) == true ? 0.6 : 0.45)).rounded(.up)
        let smol = (canvas * 0.05).rounded(.up)
        while candidate >= smol {
            let font = CTFontCreateWithName(AxoFonts.interName(weight: 400) as CFString, candidate, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if ink.width < diameter && ink.height < diameter { return candidate }
            candidate -= 1
        }
        return candidate
    }

    public var body: some View {
        let colors = data.color.map { AxoTokens.Avatar.colorValues($0) }
        let scale = size / Self.canvas
        ZStack {
            if let image = data.image {
                PixelImage(image, fit: .cover)
            } else if let colors, let text = data.text {
                Rectangle().fill(AxoColor(colors.bg))
                let fontSize = Self.fittedFontSize(text)
                // textBaseline middle: the em box's middle on y = 512 + 30.
                Text(text)
                    .font(.custom(AxoFonts.interName(weight: 400), fixedSize: fontSize * scale))
                    .foregroundStyle(AxoColor(colors.fg))
                    .fixedSize()
                    .position(x: size / 2, y: (Self.canvas / 2 + 30) * scale)
            } else if let colors, let icon = data.icon {
                Rectangle().fill(AxoColor(colors.bg))
                SignalIcon("avatars/avatar_\(icon)", size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// `.BetterAvatarBubble`: a round button, 2px border (black / white when selected) and 2px
/// padding around its content-box background; a delete badge shows on hover.
public struct BetterAvatarBubble<Content: View>: View {
    let color: String?
    let isSelected: Bool
    let diameter: CGFloat
    let background: AnyView?
    let onDelete: (() -> Void)?
    let onSelect: () -> Void
    let content: Content
    @State private var hovered = false
    @Environment(\.i18n) var i18n

    public init(color: String? = nil, isSelected: Bool = false, diameter: CGFloat = 56, background: AnyView? = nil, onDelete: (() -> Void)? = nil,
                onSelect: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.color = color
        self.isSelected = isSelected
        self.diameter = diameter
        self.background = background
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.content = content()
    }

    public var body: some View {
        let colors = color.map { AxoTokens.Avatar.colorValues($0) }
        ZStack {
            Circle().fill(colors.map { AxoColor($0.bg) } ?? AxoColor(RGBA(0, 0, 0, 0))).padding(4)
            if let background { background.frame(width: diameter - 8, height: diameter - 8).clipShape(Circle()) }
            content
                .font(.custom(AxoFonts.interName(weight: 400), fixedSize: 32))
                .modifier(Avatar.InheritedTextColor(color: colors.map { AxoColor($0.fg) }))
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle().strokeBorder(isSelected ? AxoColor(light: LegacyColor.black, dark: LegacyColor.white) : AxoColor(RGBA(0, 0, 0, 0)), lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if let onDelete, hovered {
                SwiftUI.Button(action: onDelete) {
                    SignalIcon("v3/x/x-compact", size: 10, color: AxoColor(LegacyColor.gray75))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(AxoColor(LegacyColor.white))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4).shadow(color: .black.opacity(0.2), radius: 2, y: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:delete"))
            }
        }
        .contentShape(Circle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }
}

/// `BetterAvatar`: the avatar at `size` in a bubble of `size + 8`, with the edit overlay when
/// selected and editable (it has a colour); deletable unless it is a preset icon.
public struct BetterAvatar: View {
    let avatarData: AvatarData
    let isSelected: Bool
    let size: CGFloat
    let onClick: () -> Void
    let onDelete: () -> Void

    public init(avatarData: AvatarData, isSelected: Bool = false, size: CGFloat = 48, onClick: @escaping () -> Void = {},
                onDelete: @escaping () -> Void = {}) {
        self.avatarData = avatarData
        self.isSelected = isSelected
        self.size = size
        self.onClick = onClick
        self.onDelete = onDelete
    }

    public var body: some View {
        let isEditable = avatarData.color != nil
        BetterAvatarBubble(isSelected: isSelected, diameter: size + 8, background: AnyView(AvatarDataImage(data: avatarData, size: size)),
                           onDelete: avatarData.icon == nil ? onDelete : nil, onSelect: onClick) {
            if isEditable && isSelected {
                // --editable: black-alpha-20 with the white edit icon
                SignalIcon("v3/edit/edit", size: 24, color: AxoColor(LegacyColor.white))
                    .frame(width: size, height: size)
                    .background(Circle().fill(AxoColor(LegacyColor.blackAlpha20)))
            }
        }
    }
}
