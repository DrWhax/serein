// Port of ts/axo/_internal/AxoBaseMenu.dom.tsx: the shared look of dropdown / context
// menus (and select lists).
//   content: min-w 200 max-w 300, curved-xl, material-tertiary, shadow-elevation-3,
//            grid [min-content leading | 1fr content], p-1.5
//   item:    subgrid row, p-1.5, curved-md, type-body-medium text-primary,
//            highlighted bg-primary-pressed, disabled text-disabled
//   label:   p-1.5 type-body-small text-secondary;  separator: my-1, 1px border-primary

import SwiftUI

public enum AxoBaseMenu {
    /// What an item puts in the leading column (decides that column's width).
    public struct Leading: Sendable, Hashable {
        public var checkPlaceholder = false     // w-3.5 (14)
        public var symbol = false               // 16
        /// A custom leading node's width (`CustomItem`).
        public var custom: CGFloat? = nil
        public init(checkPlaceholder: Bool = false, symbol: Bool = false, custom: CGFloat? = nil) {
            self.checkPlaceholder = checkPlaceholder
            self.symbol = symbol
            self.custom = custom
        }
        /// ItemLeadingSlot: flex gap-1.5 me-1.5
        var width: CGFloat {
            let parts = [checkPlaceholder ? 14 : nil, symbol ? 16 : nil, custom].compactMap { $0 } as [CGFloat]
            guard !parts.isEmpty else { return 0 }
            return parts.reduce(0, +) + 6 * CGFloat(parts.count - 1) + 6
        }
    }

    /// `menuContentClassName`: the menu panel. Its rows share the leading column, as
    /// CSS subgrid rows do: the column is as wide as the widest row's leading slot.
    public struct Content<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            let shape = SuperellipseRect.curved(12)
            // The rows' container values give the column width; environment values don't
            // reach into already-resolved subviews, so the content is rendered again with it.
            Group(subviews: inner) { rows in
                let leading = rows.map { $0.containerValues.axoMenuLeadingWidth }.max() ?? 0
                VStack(alignment: .leading, spacing: 0) { inner }
                    .environment(\.axoMenuLeadingColumn, leading)
            }
            .padding(6)
            .modifier(ClampedWidth(min: 200, max: 300))
            .background(shape.fill(AxoColor.materialTertiary))
            .clipShape(shape)
            .axoShadow(.shadowElevation3, in: shape)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    /// CSS `min-w-[200px] max-w-[300px]` on a shrink-to-fit box: width = clamp(max-content),
    /// then the height of the content laid out at that width.
    struct ClampedWidth: ViewModifier {
        let min: CGFloat, max: CGFloat
        func body(content: Self.Content) -> some View { Layout(min: min, max: max) { content } }
        struct Layout: SwiftUI.Layout {
            let min: CGFloat, max: CGFloat
            func width(_ subviews: Subviews) -> CGFloat {
                Swift.min(max, Swift.max(min, subviews.first?.sizeThatFits(.unspecified).width ?? 0))
            }
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                let w = width(subviews)
                return CGSize(width: w, height: subviews.first?.sizeThatFits(ProposedViewSize(width: w, height: nil)).height ?? 0)
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    /// One navigable row: leading slot (in the shared column) + content slot. The item
    /// view must declare its `Leading` with `.axoMenuLeading(_:)` on its own body (container
    /// values only reach the menu from a row's top-level modifiers).
    public struct Row<LeadingView: View, Main: View>: View {
        let leading: Leading
        let disabled: Bool
        let highlighted: Bool
        let leadingView: LeadingView
        let main: Main
        @Environment(\.axoMenuLeadingColumn) var column

        public init(leading: Leading, disabled: Bool = false, highlighted: Bool = false, @ViewBuilder leadingView: () -> LeadingView,
                    @ViewBuilder main: () -> Main) {
            self.leading = leading
            self.disabled = disabled
            self.highlighted = highlighted
            self.leadingView = leadingView()
            self.main = main()
        }

        public var body: some View {
            HStack(spacing: 0) {
                HStack(spacing: 6) { leadingView }
                    .frame(width: max(0, column - (column > 0 ? 6 : 0)), alignment: .leading)
                    .padding(.trailing, column > 0 ? 6 : 0)
                // ItemContentSlot: flex min-w-0 items-center (label shrinks/truncates, suffix ms-auto)
                CSSFlex(.row, align: .center) { main }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .cssTextColor(disabled ? .labelDisabled : .labelPrimary)
            .background { if highlighted { SuperellipseRect.curved(6).fill(AxoColor.fillPrimaryPressed) } }
        }
    }

    /// `ItemText`: truncating label.
    @MainActor public static func itemText(_ s: String) -> some View {
        CSSText(s, type: .bodyMedium, wrap: .truncate).flexItem(minMain: 0)        // flex-auto grow-0 truncate
    }

    /// `ItemText` with styled runs (e.g. a `<strong>` prefix); `runs` nil: the plain text.
    @MainActor public static func itemText(_ s: String, runs: [CSSTextRun]?) -> some View {
        CSSText(runs: runs ?? [CSSTextRun(s)], style: CSSTextStyle(AxoType.bodyMedium), wrap: .truncate).flexItem(minMain: 0)
    }

    /// `ItemKeyboardShortcut`: ms-auto px-1 type-body-medium text-secondary.
    @MainActor public static func keyboardShortcut(_ s: String) -> some View {
        CSSText(s, type: .bodyMedium, wrap: .nowrap, color: .labelSecondary).padding(.horizontal, 4)
            .flexItem(shrink: 0, autoMarginStart: true)
    }

    /// `ItemCheckPlaceholder` (w-3.5) with `ItemCheck` (14px check) when checked.
    @MainActor public static func checkPlaceholder(_ checked: Bool) -> some View {
        ZStack { if checked { AxoSymbol.Icon("check", size: 14, label: nil) } }.frame(width: 14)
    }

    /// `ItemSymbol`
    @MainActor public static func symbol(_ name: AxoSymbol.Name) -> some View { AxoSymbol.Icon(name, size: 16, label: nil) }

    /// `menuLabelClassName`
    public struct Label: View {
        let text: String
        var runs: [CSSTextRun]?
        @Environment(\.axoMenuLeadingColumn) var column
        public init(_ text: String) { self.text = text }
        /// The label as styled runs.
        public func runs(_ runs: [CSSTextRun]) -> Self { var c = self; c.runs = runs; return c }
        public var body: some View {
            CSSText(runs: runs ?? [CSSTextRun(text)], style: CSSTextStyle(AxoType.bodySmall), wrap: .truncate, color: .labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, column)
                .padding(6)
        }
    }

    /// `menuSeparatorClassName`: col-span-full mx-0.5 my-1, 1px border-primary.
    public struct Separator: View {
        public init() {}
        public var body: some View {
            Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).padding(.horizontal, 2).padding(.vertical, 4)
        }
    }

    /// `menuContentSeparatorClassName`: the separator from the content column (col-start-2).
    public struct ContentSeparator: View {
        @Environment(\.axoMenuLeadingColumn) var column
        public init() {}
        public var body: some View {
            Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).padding(.horizontal, 2).padding(.vertical, 4)
                .padding(.leading, column > 0 ? column + 6 - 2 : 0)
        }
    }

    /// `menuHeaderClassName`: title-small label + caption description.
    public struct Header: View {
        let label: String
        let description: String?
        public init(label: String, description: String?) {
            self.label = label
            self.description = description
        }
        public var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                CSSText(label, type: .titleSmall, wrap: .truncate, color: .labelPrimary)
                if let description { CSSText(description, type: .caption, wrap: .truncate, color: .labelSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Declares a menu row's leading slot so the menu can size the shared leading column.
    public func axoMenuLeading(_ leading: AxoBaseMenu.Leading) -> some View {
        containerValue(\.axoMenuLeadingWidth, leading.width)
    }
}

extension ContainerValues {
    @Entry var axoMenuLeadingWidth: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var axoMenuLeadingColumn: CGFloat = 0
}
