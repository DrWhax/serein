// Port of ts/axo/AxoAvatar.dom.tsx: Root (size + story ring), Content (img / button),
// Icon, Initials, Gradient, ClickToView. Image, Preset and Badge render through the
// SVG/raster pipeline (Phase 3 media) and are added with it.

import SwiftUI

public enum AxoAvatar {
    public typealias Size = CGFloat
    /// `_getAllSizes()`
    public static let allSizes: [Size] = [20, 24, 28, 30, 32, 36, 38, 40, 48, 52, 64, 72, 80, 96, 216]
    public static let minClickToViewSize: Size = 80

    public enum Ring: Sendable { case unread, read }

    /// Ring border width and padding (RingSizes).
    static func ring(_ size: Size) -> (border: CGFloat, padding: CGFloat) {
        switch size {
        case ..<28: (1, 1.5)
        case ..<48: (1.5, 2)
        case ..<72: (2, 3)
        case ..<96: (2.5, 3.5)
        case ..<216: (3, 4)
        default: (4, 6)
        }
    }

    struct SizeKey: EnvironmentKey { static let defaultValue: Size = 0 }
    struct RootSizeKey: EnvironmentKey { static let defaultValue: Size = 0 }

    /// `<AxoAvatar.Root>`
    public struct Root<Content: View>: View {
        let size: Size
        let ring: Ring?
        let content: Content
        public init(size: Size, ring: Ring? = nil, @ViewBuilder content: () -> Content) {
            self.size = size
            self.ring = ring
            self.content = content()
        }

        public var body: some View {
            let (border, padding) = ring.map { _ in AxoAvatar.ring(size) } ?? (0, 0)
            let inner = size - 2 * (border + padding)
            ZStack { content }
                .environment(\.axoAvatarSize, inner)
                .environment(\.axoAvatarRootSize, size)
                .frame(width: inner, height: inner)
                .padding(border + padding)
                .overlay {
                    if let ring {
                        Circle().strokeBorder(ring == .unread ? AxoColor.borderSelected : AxoColor.labelSecondary, lineWidth: border)
                    }
                }
                .frame(width: size, height: size)
        }
    }

    /// `<AxoAvatar.Content>`: the clipped circle (a button when `action` is set).
    public struct Content<Inner: View>: View {
        let label: String?
        let action: (() -> Void)?
        let inner: Inner
        public init(label: String?, action: (() -> Void)? = nil, @ViewBuilder content: () -> Inner) {
            self.label = label
            self.action = action
            inner = content()
        }
        public var body: some View {
            let circle = ZStack { inner }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(Circle())
            if let action {
                Button(action: action) { circle }.buttonStyle(.plain).accessibilityLabel(label ?? "")
            } else {
                circle.accessibilityElement().accessibilityLabel(label ?? "").accessibilityHidden(label == nil)
            }
        }
    }

    /// `<AxoAvatar.Icon>`: a glyph at 55% of the avatar size on an avatar colour (default: fill-primary).
    public struct Icon: View {
        let symbol: AxoSymbol.Name
        let color: String?
        @Environment(\.axoAvatarRootSize) var size
        public init(symbol: AxoSymbol.Name, color: String? = nil) {
            self.symbol = symbol
            self.color = color
        }
        public var body: some View {
            let values = color.map { AxoTokens.Avatar.colorValues($0) }
            ZStack {
                AxoSymbol.InlineGlyph(symbol, size: size * 0.55, weight: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cssTextColor(values.map { AxoColor($0.fg) } ?? .labelPrimary)
            .background(Circle().fill(values.map { AxoColor($0.bg) } ?? .fillPrimary))
        }
    }

    /// `<AxoAvatar.Image>`: the profile image cover-fitted in the circle; nil (failed to load)
    /// shows `fallbackIcon` on `fallbackColor`. `blur`: blur-thin (8px), the image zoomed 110%;
    /// the fallback stays blurred too.
    public struct Image: View {
        let image: RGBAImage?
        let blur: Bool
        let fallbackIcon: AxoSymbol.Name
        let fallbackColor: String
        public init(_ image: RGBAImage?, blur: Bool = false, fallbackIcon: AxoSymbol.Name = "person", fallbackColor: String) {
            self.image = image
            self.blur = blur
            self.fallbackIcon = fallbackIcon
            self.fallbackColor = fallbackColor
        }
        public var body: some View {
            if let image {
                PixelImage(image, fit: .cover).clipShape(Circle())
                    .scaleEffect(blur ? 1.1 : 1)
                    .blur(radius: blur ? 8 : 0)
            } else {
                // The fallback: a square div in the avatar colour (the Content clips it to the
                // circle) under an Icon in its default colours (fill-primary, label-primary).
                let values = AxoTokens.Avatar.colorValues(fallbackColor)
                Icon(symbol: fallbackIcon)
                    .background(AxoColor(values.bg))
                    .blur(radius: blur ? 8 : 0)
            }
        }
    }

    /// `<AxoAvatar.Preset>`: a built-in illustration (images/avatars/avatar_<preset>.svg) on
    /// its preset colour.
    public struct Preset: View {
        let preset: String
        @Environment(\.axoAvatarSize) var size
        public init(preset: String) { self.preset = preset }
        public var body: some View {
            let values = AxoTokens.Avatar.colorValues(AxoTokens.Avatar.presetColorName(preset))
            SignalIcon("avatars/avatar_\(preset)", size: size)
                .frame(width: size, height: size)
                .background(AxoColor(values.bg))
                .clipShape(Circle())
        }
    }

    /// `<AxoAvatar.Initials>`: 46.875% of the avatar width, line-height 1, centred.
    public struct Initials: View {
        let initials: String
        let color: String
        @Environment(\.axoAvatarSize) var size
        public init(initials: String, color: String) {
            self.initials = initials
            self.color = color
        }
        public var body: some View {
            let values = AxoTokens.Avatar.colorValues(color)
            let fontSize = size * 0.46875
            ZStack {
                CSSText(initials, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: fontSize, lineHeight: fontSize,
                                                     letterSpacing: -0.084), wrap: .nowrap, color: AxoColor(values.fg))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Circle().fill(AxoColor(values.bg)))
            .accessibilityHidden(true)
        }
    }

    /// `<AxoAvatar.Gradient>`: top-to-bottom gradient chosen by `hash % 20`.
    public struct Gradient: View {
        let identifierHash: Int
        public init(identifierHash: Int) { self.identifierHash = identifierHash }
        public var body: some View {
            let g = AxoTokens.Avatar.gradient(hash: identifierHash)
            CSSLinearGradientFill(CSSLinearGradient(deg: 180, start: g.start, end: g.end)).clipShape(Circle())
        }
    }

    /// `<AxoAvatar.ClickToView>`: dimmed overlay with a press icon and label (sizes ≥ 80).
    public struct ClickToView: View {
        let label: String
        @State private var hovered = false
        @Environment(\.axoAvatarSize) var size
        public init(label: String) { self.label = label }
        public var body: some View {
            VStack(spacing: 8) {
                AxoSymbol.Icon("press", size: 24, label: nil)
                CSSText(label, type: .bodyMedium, wrap: .nowrap)
            }
            .cssTextColor(AxoColor(RGBA(1, 1, 1)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Circle().fill(Color.black.opacity(hovered ? 0.4 : 0.2)))
            .onHover { hovered = $0 }
        }
    }
}

extension EnvironmentValues {
    /// `AxoAvatar.Root` size (SizeContext).
    var axoAvatarRootSize: AxoAvatar.Size {
        get { self[AxoAvatar.RootSizeKey.self] }
        set { self[AxoAvatar.RootSizeKey.self] = newValue }
    }
    /// The avatar content diameter (`AxoAvatar` SizeContext, minus any ring).
    var axoAvatarSize: AxoAvatar.Size {
        get { self[AxoAvatar.SizeKey.self] }
        set { self[AxoAvatar.SizeKey.self] = newValue }
    }
}
