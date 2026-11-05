// Ports of ts/components/fun/base/* (FunPopover, FunPanel, FunSubNav, FunScroller, FunGrid,
// FunItem, FunResults) and stylesheets/components/fun/*.scss: the shared frame of the emoji,
// sticker and GIF pickers. A 352px popover (8px corners, material-dialog, a 0 8px 20px
// shadow) holding a panel: a 12px-padded header, a scrolling body of sectioned grids and a
// footer sub-nav of 32px category buttons (the selected one on fill-primary-pressed).

import SignalI18n
import SwiftUI

public enum FunMetrics {
    /// `$Fun__DialogWidth` / `$Fun__DialogHeight` / `$Fun__TabsListHeight`
    public static let dialogWidth: CGFloat = 352
    public static let dialogHeight: CGFloat = 524
    public static let tabsListHeight: CGFloat = 48
    public static var panelHeight: CGFloat { dialogHeight - tabsListHeight }
}

/// `.FunPopover__Dialog`
public struct FunPopoverDialog<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    static var shadow: [AxoShadowLayer] { [AxoShadowLayer(inset: false, x: 0, y: 8, blur: 20, spread: 0, color: LegacyColor.blackAlpha30)] }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        content
            .background(shape.fill(AxoColor.materialDialog))
            .clipShape(shape)
            .cssBoxShadow(Self.shadow, in: shape)
    }
}

/// `FunPanel`: header (12px padding, 6px gaps), body, footer; 352 × 476.
public struct FunPanel<Header: View, Body: View, Footer: View>: View {
    let header: Header
    let content: Body
    let footer: Footer
    let headerTopPadding: CGFloat
    @Environment(\.funPanelInTabs) var inTabs
    public init(headerTopPadding: CGFloat = 12, @ViewBuilder header: () -> Header, @ViewBuilder body: () -> Body, @ViewBuilder footer: () -> Footer) {
        self.headerTopPadding = headerTopPadding
        self.header = header()
        self.content = body()
        self.footer = footer()
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { header }
                .padding(.horizontal, 12)
                .padding(.top, inTabs ? 0 : headerTopPadding)     // .FunTabs__TabPanelInner .FunPanel__Header
                .padding(.bottom, 12)
            content.frame(maxHeight: .infinity)
            footer
        }
        .frame(width: FunMetrics.dialogWidth, height: inTabs ? FunMetrics.dialogHeight - FunMetrics.tabsListHeight : FunMetrics.panelHeight)
    }
}

/// `FunSubNavListBox` + items: equal-width items (1px padding; 6px at the ends) holding a
/// 32px button with a 20px label-secondary icon; hover fill-primary, selected
/// fill-primary-pressed.
public struct FunSubNavListBox<ID: Hashable>: View {
    public struct Item {
        public var id: ID
        public var label: String
        public var icon: String
        public init(id: ID, label: String, icon: String) {
            self.id = id
            self.label = label
            self.icon = icon
        }
    }
    let items: [Item]
    let selected: ID?
    let onSelect: (ID) -> Void

    public init(items: [Item], selected: ID?, onSelect: @escaping (ID) -> Void) {
        self.items = items
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                FunSubNavItemButton(icon: items[i].icon, label: items[i].label, isSelected: items[i].id == selected) { onSelect(items[i].id) }
                    .padding(.vertical, 1)
                    .padding(.leading, i == 0 ? 6 : 1)
                    .padding(.trailing, i == items.count - 1 ? 6 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

struct FunSubNavItemButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        SwiftUI.Button(action: action) {
            SignalIcon(icon, size: 20, color: .labelSecondary, mask: true)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? AxoColor.fillPrimaryPressed
                                                                      : hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// `FunScroller`: the body's scroll view (12px leading, 1px trailing padding) with 2px
/// elevation-1 shade hints at the top and bottom while there is more to scroll that way.
public struct FunScroller<Content: View>: View {
    let content: Content
    @State private var atTop = true
    @State private var atBottom = false
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.colorScheme) var scheme

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        let inner = content.padding(.leading, 12).padding(.trailing, 1)
        Group {
            if staticRendering {
                Color.clear.overlay(alignment: .top) { inner.fixedSize(horizontal: false, vertical: true) }.clipped()
            } else {
                ScrollView(.vertical) { inner }
                    .scrollIndicators(.automatic)
                    .onScrollGeometryChange(for: [Bool].self) { g in
                        [g.contentOffset.y <= 0, g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 0.5]
                    } action: { _, v in
                        atTop = v[0]
                        atBottom = v[1]
                    }
            }
        }
        .overlay(alignment: .top) { hint(top: true).opacity(atTop ? 0 : 1) }
        .overlay(alignment: .bottom) { hint(top: false).opacity(staticRendering || !atBottom ? 1 : 0) }
    }

    func hint(top: Bool) -> some View {
        LinearGradient(colors: [AxoColor.shadowColorElevation1.value(for: scheme).color, .clear], startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top)
            .frame(height: 2)
            .allowsHitTesting(false)
    }
}

/// `FunGridHeader` + `FunGridHeaderText`: a 28px row, body-2 semibold label-secondary.
struct FunGridHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 0) {
            CSSText(title, style: LegacyType.body2(weight: 600), wrap: .nowrap, color: .labelSecondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(height: 28)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `FunItemButton`: fills its cell, 2px padding, 10px corners; fill-primary on hover.
struct FunItemButton<Content: View>: View {
    let label: String
    let action: () -> Void
    let content: Content
    @State private var hovered = false
    init(label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.label = label
        self.action = action
        self.content = content()
    }
    var body: some View {
        SwiftUI.Button(action: action) {
            content
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// `FunResults` + header: centred body-1 label-secondary text (empty results).
struct FunResultsHeader: View {
    let runs: [CSSTextRun]
    var body: some View {
        CSSText(runs: runs, style: LegacyType.body1(), wrap: .balance, alignment: .center, color: .labelSecondary)
            .padding(.vertical, 12).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    /// A panel inside FunPicker's tabs (its header has no top padding).
    @Entry var funPanelInTabs = false
}
