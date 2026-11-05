// Port of ts/components/Avatar.dom.tsx + stylesheets/components/Avatar.scss: the legacy
// (pre-AxoAvatar) avatar used across the app. Contents, in upstream's order of precedence:
// loading spinner, image, search icon, note-to-self icon, placeholder gradient, initials,
// conversation-type icon. Colours come from AxoTokens.Avatar (bg / fg of the colour name).
//
// Not ported yet (need the raster / SVG media pipeline): the avatar image itself (`image` is
// a caller-supplied view drawn as `background-size: cover`; upstream loads `avatarUrl`), the
// badge image, and the click-to-view hand icon (v2/click-outline-24.svg, a stroked SVG).
// Mask icons (person, group, note, search) are LegacyIcon paths.

import SwiftUI

/// `AvatarSize` (upstream order)
public enum AvatarSize: CGFloat, Sendable, Hashable, CaseIterable {
    case twenty = 20, twentyFour = 24, twentyEight = 28, thirty = 30, thirtyTwo = 32, thirtySix = 36, forty = 40, fortyEight = 48
    case fiftyTwo = 52, seventyTwo = 72, sixtyFour = 64, eighty = 80, ninetySix = 96, twoHundredSixteen = 216
}

/// `AvatarBlur`
public enum AvatarBlur: Sendable, Hashable { case noBlur, blurPicture, blurPictureWithClickToView }

/// `AvatarConversationType`
public enum AvatarConversationType: Sendable, Hashable { case group, direct, callLink }

/// `HasStories`
public enum HasStories: Sendable, Hashable { case read, unread }

/// i18n: `icu:contactAvatarAlt` ({name}), `icu:unknownContact`, `icu:deletedAccount`, `icu:Avatar__View`.
public struct AvatarStrings: Sendable {
    public var contactAvatarAlt: @Sendable (String) -> String
    public var unknownContact: String
    public var deletedAccount: String
    public var view: String
    public init(contactAvatarAlt: @escaping @Sendable (String) -> String, unknownContact: String, deletedAccount: String, view: String) {
        self.contactAvatarAlt = contactAvatarAlt
        self.unknownContact = unknownContact
        self.deletedAccount = deletedAccount
        self.view = view
    }
}

public struct Avatar: View {
    let strings: AvatarStrings
    let title: String
    let size: CGFloat
    let conversationType: AvatarConversationType
    let color: String
    let image: AnyView?
    let hasAvatar: Bool
    let placeholderGradient: (start: RGBA, end: RGBA)
    let loading: Bool
    let noteToSelf: Bool
    let searchResult: Bool
    let storyRing: HasStories?
    let blur: AvatarBlur
    /// `module-Avatar--signal-official`: #3640fd behind the image, drawn at 62%.
    let signalOfficial: Bool
    let onClick: (() -> Void)?

    public init(strings: AvatarStrings, title: String, size: CGFloat, conversationType: AvatarConversationType, color: String = "A200",
                image: AnyView? = nil, hasAvatar: Bool = false, placeholderGradient: (start: RGBA, end: RGBA) = AxoTokens.Avatar.gradient(hash: 0),
                loading: Bool = false, noteToSelf: Bool = false, searchResult: Bool = false, storyRing: HasStories? = nil,
                blur: AvatarBlur = .noBlur, signalOfficial: Bool = false, onClick: (() -> Void)? = nil) {
        self.signalOfficial = signalOfficial
        self.strings = strings
        self.title = title
        self.size = size
        self.conversationType = conversationType
        self.color = color
        self.image = image
        self.hasAvatar = hasAvatar
        self.placeholderGradient = placeholderGradient
        self.loading = loading
        self.noteToSelf = noteToSelf
        self.searchResult = searchResult
        self.storyRing = storyRing
        self.blur = blur
        self.onClick = onClick
    }

    /// `getInitials` (ts/util/getInitials.std.ts): letters and separators only; two
    /// upper-case letters are kept as they are, otherwise the first letter of the first and
    /// last words.
    public static func initials(_ name: String) -> String? {
        var parsed = ""
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                if pendingSpace && !parsed.isEmpty { parsed.append(" ") }
                pendingSpace = false
                parsed.unicodeScalars.append(scalar)
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                pendingSpace = true
            default:
                break
            }
        }
        guard !parsed.isEmpty else { return nil }
        if parsed.count == 2 && parsed == parsed.uppercased() { return parsed }
        let parts = parsed.split(separator: " ")
        guard let first = parts.first?.first else { return nil }
        if parts.count == 1 { return String(first) }
        return String(first) + (parts.last?.first.map { String($0) } ?? "")
    }

    var colorValues: AxoTokens.Avatar.ColorValues? {
        AxoTokens.Avatar.allColorNames.contains(color) ? AxoTokens.Avatar.colorValues(color) : nil
    }

    /// `--with-story`: a 2px ring and 3px padding inside the avatar's size.
    var ringInset: CGFloat { storyRing == nil ? 0 : 5 }

    public var body: some View {
        let inner = size - 2 * ringInset
        let values = colorValues
        // An undefined --module-Avatar__contents-fg leaves `color` inherited.
        let fg = values.map { AxoColor($0.fg) }
        Group {
            if let onClick {
                SwiftUI.Button(action: onClick) { contents(inner: inner, fg: fg, bg: values.map { AxoColor($0.bg) }) }
                    .buttonStyle(.plain)
            } else {
                contents(inner: inner, fg: fg, bg: values.map { AxoColor($0.bg) })
            }
        }
        .padding(ringInset)
        .overlay {
            if let storyRing {
                Circle().strokeBorder(storyRing == .unread ? AxoColor(LegacyColor.ultramarineDawn)
                                      : AxoColor(light: LegacyColor.blackAlpha40, dark: LegacyColor.whiteAlpha40), lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.contactAvatarAlt(title))
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
    }

    /// `.module-Avatar__contents`: the clipped circle with the contents children.
    func contents(inner: CGFloat, fg: AxoColor?, bg: AxoColor?) -> some View {
        let showsImage = image != nil && !noteToSelf
        return ZStack {
            if let bg, !showsImage && !(hasAvatar && image == nil && !noteToSelf && !searchResult && !loading) { Circle().fill(bg) }
            children(inner: inner, fg: fg)
        }
        .frame(width: inner, height: inner)
        .clipShape(Circle())
        .modifier(InheritedTextColor(color: fg))
    }

    struct InheritedTextColor: ViewModifier {
        let color: AxoColor?
        func body(content: Content) -> some View {
            if let color { content.cssTextColor(color) } else { content }
        }
    }

    @ViewBuilder func children(inner: CGFloat, fg: AxoColor?) -> some View {
        let initials = Self.initials(title)
        let hasLocalImage = !noteToSelf && image != nil
        let shouldUseInitials = !hasLocalImage && conversationType == .direct && initials != nil
            && title != strings.unknownContact && title != strings.deletedAccount
        if loading {
            // .module-Avatar__spinner-container: padding 4px; Spinner size − 8, on-avatar
            Spinner(svgSize: size < 40 ? .small : .normal, direction: .onAvatar, size: size - 8).padding(4)
        } else if let image, hasLocalImage, signalOfficial {
            ZStack {
                Circle().fill(Color(.sRGB, red: 0x36 / 255, green: 0x40 / 255, blue: 0xFD / 255))
                image.frame(width: inner * 0.62, height: inner * 0.62)
            }
        } else if let image, hasLocalImage {
            let isBlurred = blur != .noBlur
            ZStack {
                image.blur(radius: isBlurred ? (size / 2).rounded(.up) : 0)
                if blur == .blurPictureWithClickToView { ClickToView(label: strings.view) }
            }
        } else if searchResult {
            AvatarIcon(icon: .search, color: fg)
        } else if noteToSelf {
            AvatarIcon(icon: .note, color: fg)
        } else if hasAvatar {
            ZStack {
                LinearGradient(colors: [placeholderGradient.start.color, placeholderGradient.end.color], startPoint: .top, endPoint: .bottom)
                if blur == .blurPictureWithClickToView { ClickToView(label: strings.view) }
            }
        } else if shouldUseInitials, let initials {
            AvatarLabel(initials: initials, fontSize: (size * 0.45).rounded(.up))
        } else if conversationType == .callLink {
            // .module-Avatar__icon--callLink: video-display-bold, mask-size 62.5%.
            SignalIcon("v3/video/video-display-bold", size: size * 0.625, color: fg, mask: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AvatarIcon(icon: conversationType == .group ? .group : .person, color: fg)
        }
    }
}

/// `.module-Avatar__icon`: currentColor through the icon mask at 62.5%.
struct AvatarIcon: View {
    let icon: LegacyIcon
    let color: AxoColor?
    @Environment(\.cssTextColor) var inherited
    var body: some View { LegacyIcon.Mask(icon, color: color ?? inherited, maskSize: 0.625) }
}

/// `.module-Avatar__label`: the initials centred, font-size ceil(size × 0.45), inside
/// `.module-Avatar`'s line-height: 0. A zero-height line box centres the glyphs' content
/// area on the label's middle; an even, integral line box of the same centre puts the
/// baseline in the same place (Blink: round(ascent) + floor((lh − round(a) − round(d)) / 2)).
struct AvatarLabel: View {
    let initials: String
    let fontSize: CGFloat
    var body: some View {
        let lineHeight = 2 * fontSize.rounded(.up)
        CSSText(initials, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: fontSize, lineHeight: lineHeight,
                                              letterSpacing: -0.084), wrap: .nowrap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// `.module-Avatar__click-to-view`: font-body-2, white on black-alpha-20 (hover 40), a 24px
/// icon (not drawn yet: v2/click-outline-24.svg is stroked) 8px above the label.
struct ClickToView: View {
    let label: String
    @State private var hovered = false
    var body: some View {
        VStack(spacing: 8) {
            Color.clear.frame(width: 24, height: 24)
            CSSText(label, style: LegacyType.body2(), wrap: .nowrap, color: AxoColor(LegacyColor.white))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AxoColor(hovered ? LegacyColor.blackAlpha40 : LegacyColor.blackAlpha20))
        .onHover { hovered = $0 }
    }
}
