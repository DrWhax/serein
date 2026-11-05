// ListTile (ts/components/ListTile.dom.tsx, stylesheets/components/ListTile.scss): a list row
// of leading widget, one-line title, 1–3-line subtitle and trailing widget. The background is
// inset by a transparent 2px × 10px border (radius 10 on the padding box) and shows on hover
// when clickable. `ListTile.checkbox` puts a CircleCheckbox at the end.

import SwiftUI

public struct ListTile<Leading: View, Title: View, Subtitle: View, Trailing: View>: View {
    public enum Variant: Sendable { case item, panelrow }

    let leading: Leading?
    let title: Title
    let subtitle: Subtitle?
    let trailing: Trailing?
    let onClick: (() -> Void)?
    let clickable: Bool
    let subtitleMaxLines: Int
    let disabled: Bool
    let variant: Variant
    let selected: Bool
    @Environment(\.colorScheme) var scheme
    @State private var hovered = false

    public init(variant: Variant = .item, clickable: Bool? = nil, subtitleMaxLines: Int = 2, disabled: Bool = false, selected: Bool = false,
                onClick: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder title: () -> Title,
                @ViewBuilder subtitle: () -> Subtitle, @ViewBuilder trailing: () -> Trailing) {
        let l = leading(), s = subtitle(), t = trailing()
        self.leading = l is EmptyView ? nil : l
        self.title = title()
        self.subtitle = s is EmptyView ? nil : s
        self.trailing = t is EmptyView ? nil : t
        self.onClick = onClick
        self.clickable = clickable ?? (onClick != nil)
        self.subtitleMaxLines = subtitleMaxLines
        self.disabled = disabled
        self.variant = variant
        self.selected = selected
    }

    /// `__title`: 14px/20px, one line.
    public static var titleStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: 20, letterSpacing: -0.084) }
    /// `__subtitle`: 12px/17px, gray.
    public static var subtitleStyle: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 17, letterSpacing: -0.084) }
    public static var subtitleColor: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }

    public var body: some View {
        let showsHover = clickable && hovered && !disabled && !selected
        let tile = HStack(alignment: .center, spacing: 0) {
            if let leading { leading.padding(.trailing, 12) }
            VStack(alignment: .leading, spacing: 0) {
                title.frame(maxWidth: .infinity, alignment: .leading).frame(height: 20, alignment: .topLeading).clipped()
                if let subtitle {
                    subtitle
                        .environment(\.listTileSubtitleLines, subtitleMaxLines)
                        .cssTextColor(Self.subtitleColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing.padding(.leading, 12) }
        }
        .padding(.vertical, variant == .panelrow ? 8 : 6)
        .padding(.horizontal, variant == .panelrow ? 16 : 14)
        .background {
            if showsHover {
                RoundedRectangle(cornerRadius: 10).fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha06))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        Group {
            if let onClick, !disabled {
                tile.onTapGesture(perform: onClick).accessibilityAddTraits(.isButton)
            } else {
                tile
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension EnvironmentValues {
    @Entry var listTileSubtitleLines: Int = 2
}

/// A ListTile subtitle string, clamped to the tile's `subtitleMaxLines`.
public struct ListTileSubtitle: View {
    let runs: [CSSTextRun]
    @Environment(\.listTileSubtitleLines) var lines
    public init(_ text: String, emojify: Bool = false) {
        var run = CSSTextRun(text)
        run.emojify = emojify
        self.runs = [run]
    }
    public var body: some View {
        CSSText(runs: runs, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.subtitleStyle, wrap: .clamp(lines))
    }
}

/// `ListTile.checkbox`: the tile with a trailing CircleCheckbox (clicking anywhere toggles it).
public struct ListTileCheckbox<Leading: View, Title: View, Subtitle: View>: View {
    let isChecked: Bool
    let disabled: Bool
    let subtitleMaxLines: Int
    let onClick: () -> Void
    let leading: Leading
    let title: Title
    let subtitle: Subtitle

    public init(isChecked: Bool, disabled: Bool = false, subtitleMaxLines: Int = 2, onClick: @escaping () -> Void,
                @ViewBuilder leading: () -> Leading, @ViewBuilder title: () -> Title, @ViewBuilder subtitle: () -> Subtitle) {
        self.isChecked = isChecked
        self.disabled = disabled
        self.subtitleMaxLines = subtitleMaxLines
        self.onClick = onClick
        self.leading = leading()
        self.title = title()
        self.subtitle = subtitle()
    }

    public var body: some View {
        // `{...(disabled ? { onClick } : {})}` on the label: a disabled row still reports clicks.
        ListTile(clickable: true, subtitleMaxLines: subtitleMaxLines, disabled: disabled, onClick: nil) {
            leading
        } title: {
            title
        } subtitle: {
            subtitle
        } trailing: {
            CircleCheckbox(checked: isChecked, disabled: disabled, onClick: onClick)
        }
        .onTapGesture(perform: onClick)
    }
}
