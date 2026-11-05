// LeftPaneDialog (ts/components/LeftPaneDialog.dom.tsx, stylesheets/components/LeftPaneDialog.scss):
// the banner above the chat list used by the network-status, update, relink, clock-skew and
// other left-pane dialogs. Narrow sidebars show only the icon, with the message in a tooltip.

import SwiftUI

/// `LeftPaneDialog`'s `type`.
public enum LeftPaneDialogType: Sendable { case warning, error, info }

public struct LeftPaneDialog<Children: View>: View {
    public typealias DialogType = LeftPaneDialogType

    public enum Icon {
        case update, relink, network, warning, error
        case custom(AnyView)

        var svg: String? {
            switch self {
            case .update: "v3/refresh/refresh"
            case .relink: "v3/link/link-slash"
            case .network: "v3/wifi/wifi-error"
            case .warning: "v3/error/error-triangle"
            case .error: "v3/error/error-circle"
            case .custom: nil
            }
        }
    }

    let type: DialogType?
    let icon: Icon?
    let title: String?
    let subtitle: String?
    let hoverText: String?
    let containerWidthBreakpoint: WidthBreakpoint
    let onClick: (() -> Void)?
    let clickLabel: String?
    let hasAction: Bool
    let onClose: (() -> Void)?
    let closeLabel: String?
    /// A text child (upstream passes a string, e.g. `{i18n(...)}{' '}`): the action button
    /// flows inline after it.
    let text: String?
    let children: Children

    public init(type: DialogType? = nil, icon: Icon? = .warning, title: String? = nil, subtitle: String? = nil, hoverText: String? = nil,
                containerWidthBreakpoint: WidthBreakpoint, onClick: (() -> Void)? = nil, clickLabel: String? = nil, hasAction: Bool = false,
                onClose: (() -> Void)? = nil, closeLabel: String? = nil, text: String? = nil, @ViewBuilder children: () -> Children) {
        self.type = type
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.hoverText = hoverText
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.onClick = onClick
        self.clickLabel = clickLabel
        self.hasAction = hasAction
        self.onClose = onClose
        self.closeLabel = closeLabel
        self.text = text
        self.children = children()
    }

    var narrow: Bool { containerWidthBreakpoint == .narrow }
    var hasXButton: Bool { onClose != nil }

    /// `.LeftPaneDialog`: 13px/18px, letter-spacing -0.0025em.
    static var textStyle: CSSTextStyle {
        CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 18, letterSpacing: -0.0325)
    }

    struct Colors {
        var background: AxoColor
        var text: AxoColor
        var icon: AxoColor
        var close: AxoColor
        var action: AxoColor
        var border: AxoColor?
    }

    static func colors(_ type: DialogType?) -> Colors {
        let white = AxoColor(LegacyColor.white), black = AxoColor(LegacyColor.black)
        switch type {
        case nil:
            return Colors(background: AxoColor(LegacyColor.ultramarine), text: white, icon: white, close: white,
                          action: AxoColor(LegacyColor.whiteAlpha80))
        case .error:
            return Colors(background: AxoColor(LegacyColor.accentRed), text: white, icon: white, close: white, action: white)
        case .warning:
            return Colors(background: AxoColor(LegacyColor.accentYellow), text: black, icon: black, close: black, action: black)
        case .info:
            return Colors(background: AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75), text: .labelPrimary, icon: white,
                          close: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray20),
                          action: AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.ultramarineLight),
                          border: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray60))
        }
    }

    public var body: some View {
        if narrow {
            Tooltip(direction: .right) { message } trigger: { dialog }
        } else {
            dialog
        }
    }

    var dialog: some View {
        let c = Self.colors(type)
        let isInfo = type == .info
        let shape = RoundedRectangle(cornerRadius: isInfo ? 10 : 0)
        return HStack(alignment: .top, spacing: 0) {
            // __container
            HStack(alignment: .center, spacing: 0) {
                if let icon {
                    iconView(icon, color: c.icon)
                        .frame(width: 24, height: 24)
                        .padding(.trailing, narrow ? 0 : 18)
                }
                if !narrow { message.frame(maxWidth: 250, alignment: .leading) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: narrow ? .center : .leading)
            if hasXButton && !narrow {
                LeftPaneDialogCloseButton(label: closeLabel ?? "", color: c.close) { onClose?() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(isInfo ? 1 : 0)
        .frame(minHeight: 64)
        .background(shape.fill(c.background))
        .overlay { if let border = c.border { shape.strokeBorder(border, lineWidth: 1) } }
        .padding(.horizontal, isInfo ? 10 : 0)
        .padding(.top, isInfo ? 2 : 0)
        .padding(.bottom, isInfo ? 6 : 0)
        .cssTextColor(c.text)
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
        .help(hoverText ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
        .accessibilityLabel(onClick != nil ? (clickLabel ?? "") : "")
    }

    @ViewBuilder func iconView(_ icon: Icon, color: AxoColor) -> some View {
        if case .custom(let view) = icon {
            view
        } else if let svg = icon.svg {
            // `-webkit-mask: url() no-repeat center` resets mask-size: the 20px SVG, centred.
            SignalIcon(svg, size: 20, color: color).frame(width: 24, height: 24)
        }
    }

    @ViewBuilder var actionButton: some View {
        if let clickLabel {
            let c = Self.colors(type)
            SwiftUI.Button { onClick?() } label: {
                // An inline button in the message's 18px line box: the 12/16 info label shares
                // the 13px strut's baseline, which puts its box 2px down.
                CSSText(clickLabel, style: type == .info ? LegacyType.subtitle(weight: 600) : Self.textStyle, color: c.action)
                    .padding(.top, type == .info ? 2 : 0)
            }
            .buttonStyle(.plain)
            .help(clickLabel)
            .accessibilityLabel(clickLabel)
        }
    }

    /// `__message` (also the narrow tooltip's content): h3 title, subtitle, children, action.
    var message: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { CSSText(title, style: LegacyType.body1(weight: 600)) }
            if let subtitle { CSSText(subtitle, style: Self.textStyle) }
            children
            if let text {
                if hasAction, clickLabel != nil {
                    CSSInlineTail(text, style: Self.textStyle) { actionButton }
                } else {
                    CSSText(text, style: Self.textStyle)
                }
            } else if hasAction, clickLabel != nil {
                actionButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension LeftPaneDialog where Children == EmptyView {
    public init(type: DialogType? = nil, icon: Icon? = .warning, title: String? = nil, subtitle: String? = nil, hoverText: String? = nil,
                containerWidthBreakpoint: WidthBreakpoint, onClick: (() -> Void)? = nil, clickLabel: String? = nil, hasAction: Bool = false,
                onClose: (() -> Void)? = nil, closeLabel: String? = nil, text: String? = nil) {
        self.init(type: type, icon: icon, title: title, subtitle: subtitle, hoverText: hoverText, containerWidthBreakpoint: containerWidthBreakpoint,
                  onClick: onClick, clickLabel: clickLabel, hasAction: hasAction, onClose: onClose, closeLabel: closeLabel, text: text) { EmptyView() }
    }
}

/// `__close-button`: 20×20, radius 4, the x icon; white-alpha-20 behind it on hover/focus.
struct LeftPaneDialogCloseButton: View {
    let label: String
    let color: AxoColor
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        SwiftUI.Button(action: action) {
            SignalIcon("v3/x/x", size: 20, color: color)
                .frame(width: 20, height: 20)
                .background { if hovered { RoundedRectangle(cornerRadius: 4).fill(AxoColor(LegacyColor.whiteAlpha20)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// `LeftPaneDialogIconBackground` (warning): a yellow disc behind a black icon, with a 5px
/// outline of the same colour.
public struct LeftPaneDialogIconBackground<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .frame(width: 24, height: 24)
            .background { Circle().fill(AxoColor(LegacyColor.accentYellow)).padding(-4) }    // outline 5, offset -1
            .environment(\.leftPaneDialogIconColor, AxoColor(LegacyColor.black))
    }
}

extension EnvironmentValues {
    @Entry var leftPaneDialogIconColor: AxoColor? = nil
}
