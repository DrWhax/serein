// Port of ts/axo/AxoDialog.dom.tsx (Radix Dialog): Content (sm 320 / md 400 / lg 720),
// Header (grid: back | title | close), Title, Back, Close, Body (scrolling, max 440),
// Description, Footer, FooterContent, Actions, Action, IconAction.

import SwiftUI

public enum AxoDialog {
    public enum ContentSize: Sendable { case sm, md, lg
        var width: CGFloat { self == .sm ? 320 : self == .md ? 400 : 720 }
    }
    public enum BodyPadding: Sendable {
        case lg, md, sm
        /// `deprecated-only-scrollbar-gutter`: no inline padding (content with its own scroller).
        case onlyScrollbarGutter
        var value: CGFloat {
            switch self {
            case .lg: 24
            case .md: 16
            case .sm: 12
            case .onlyScrollbarGutter: 0
            }
        }
    }
    public enum ActionVariant: Sendable { case strongPrimary, subtleSecondary, strongDestructive, subtleDestructive
        var button: AxoButton.Variant {
            switch self {
            case .strongPrimary: .strongPrimary
            case .subtleSecondary: .subtleSecondary
            case .strongDestructive: .strongDestructive
            case .subtleDestructive: .subtleDestructive
            }
        }
    }
    public enum IconActionVariant: Sendable { case strongPrimary, strongDestructive, subtleSecondary
        var button: AxoIconButton.Variant {
            switch self {
            case .strongPrimary: .strongPrimary
            case .strongDestructive: .strongDestructive
            case .subtleSecondary: .subtleSecondary
            }
        }
    }

    struct Parts: Sendable { var header = false, footer = false }
    struct PartsKey: EnvironmentKey { static let defaultValue = Parts() }

    /// `<AxoDialog.Content>`: the panel. (Present it inside `AxoBaseDialog.Host`.)
    public struct Content<Inner: View>: View {
        let size: ContentSize
        let hasHeader: Bool
        let hasFooter: Bool
        let focused: Bool
        let inner: Inner
        /// - Parameter focused: the panel has the initial focus (nothing inside can take it).
        public init(size: ContentSize, hasHeader: Bool = true, hasFooter: Bool = true, focused: Bool = false, @ViewBuilder content: () -> Inner) {
            self.size = size
            self.hasHeader = hasHeader
            self.hasFooter = hasFooter
            self.focused = focused
            inner = content()
        }
        public var body: some View {
            AxoBaseDialog.Panel(width: size.width, content: VStack(spacing: 0) { inner }, focused: focused)
                .environment(\.axoDialogParts, Parts(header: hasHeader, footer: hasFooter))
                .accessibilityAddTraits(.isModal)
        }
    }

    enum HeaderSlot: Sendable { case back, title, close }
    struct HeaderSlotKey: LayoutValueKey { static let defaultValue = HeaderSlot.title }

    /// grid-cols-[[back-slot]_1fr_[title-slot]_auto_[close-slot]_1fr], items-center.
    struct HeaderLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return CGSize(width: proposal.width ?? 0, height: h)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let title = subviews.first { $0[HeaderSlotKey.self] == .title }
            let titleWidth = min(title?.sizeThatFits(.unspecified).width ?? 0, bounds.width)
            let side = max(0, (bounds.width - titleWidth) / 2)
            for s in subviews {
                let slot = s[HeaderSlotKey.self]
                let w = slot == .title ? titleWidth : side
                let x = slot == .back ? bounds.minX : slot == .title ? bounds.minX + side : bounds.maxX - side
                let h = s.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
                s.place(at: CGPoint(x: x, y: bounds.minY + (bounds.height - h) / 2), proposal: ProposedViewSize(width: w, height: h))
            }
        }
    }

    /// `<AxoDialog.Header>`: px-4 pt-4 pb-2.
    public struct Header<Inner: View>: View {
        let inner: Inner
        /// false when another control (an `autoFocus` action) takes the initial focus.
        let focusesClose: Bool
        /// `floating`: laid over the body (place it in an overlay; the content then has no
        /// header): the title is screen-reader only, Back and Close are material-subtle.
        let floating: Bool
        public init(floating: Bool = false, focusesClose: Bool = true, @ViewBuilder content: () -> Inner) {
            self.floating = floating
            self.focusesClose = focusesClose
            inner = content()
        }
        public var body: some View {
            // Radix focuses the first focusable control: Back if there is one, else Close.
            Group(subviews: inner) { subviews in
                let hasBack = subviews.contains { $0.containerValues.axoDialogHeaderSlot == .back }
                // (environment values don't reach into resolved subviews: render `inner` again)
                HeaderLayout { inner }
                    .environment(\.axoDialogCloseTakesFocus, focusesClose && !hasBack)
                    .environment(\.axoDialogHeaderFloating, floating)
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
        }
    }

    /// `<AxoDialog.Title>`: type-body-medium font-semibold text-primary, px-3.5 py-0.5, centred, truncated.
    public struct Title: View {
        let text: String
        @Environment(\.axoDialogHeaderFloating) var floating
        public init(_ text: String) { self.text = text }
        public var body: some View {
            CSSText(text, type: AxoType.bodyMedium.weight(600), wrap: .truncate, color: .labelPrimary)
                .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                .opacity(floating ? 0 : 1)       // sr-only
                .frame(width: floating ? 0 : nil, height: floating ? 0 : nil)
                .layoutValue(key: HeaderSlotKey.self, value: .title)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// `<AxoDialog.Title>` outside a Header: type-body-medium font-semibold text-primary, mb-2.5
    /// (`type`: an inner span's type, e.g. title-medium).
    public struct BodyTitle: View {
        let text: String
        let type: AxoType
        let alignment: CSSTextAlign
        public init(_ text: String, type: AxoType = AxoType.bodyMedium.weight(600), alignment: CSSTextAlign = .start) {
            self.text = text
            self.type = type
            self.alignment = alignment
        }
        public var body: some View {
            CSSText(text, type: type, alignment: alignment, color: .labelPrimary)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// `<AxoDialog.Back>`
    public struct Back: View {
        let action: () -> Void
        @Environment(\.axoDialogHeaderFloating) var floating
        public init(action: @escaping () -> Void) { self.action = action }
        public var body: some View {
            AxoIconButton.Root(label: "Back", tooltip: false, variant: floating ? .materialSubtle : .impliedSecondary, size: .sm, symbol: "chevron-[start]", autoFocus: true,
                               action: action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutValue(key: HeaderSlotKey.self, value: .back)
                .containerValue(\.axoDialogHeaderSlot, .back)
        }
    }

    /// `<AxoDialog.Close>`: the first focusable control, so it receives the initial focus.
    public struct Close: View {
        let action: () -> Void
        @Environment(\.dismiss) var dismiss
        @Environment(\.axoDialogCloseTakesFocus) var autoFocus
        @Environment(\.axoDialogHeaderFloating) var floating
        public init(action: (() -> Void)? = nil) {
            self.action = action ?? {}
        }
        public var body: some View {
            AxoIconButton.Root(label: "Close", tooltip: false, variant: floating ? .materialSubtle : .impliedSecondary, size: .sm, symbol: "x", autoFocus: autoFocus) {
                action()
                dismiss()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutValue(key: HeaderSlotKey.self, value: .close)
            .containerValue(\.axoDialogHeaderSlot, .close)
        }
    }

    /// `<AxoDialog.Search>`: flex items-center gap-2 px-4 pb-2, between the header and the body.
    public struct Search<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            HStack(alignment: .center, spacing: 8) { inner }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    /// `<AxoDialog.Tabs>`: a `TabList` between `Header` and the content, and each tab's `Body`
    /// in its own `TabContent`. (Upstream animates the height and cross-fades the contents.)
    public struct Tabs<Inner: View>: View {
        @Binding var value: String
        let inner: Inner
        public init(value: Binding<String>, @ViewBuilder content: () -> Inner) {
            self._value = value
            inner = content()
        }
        public var body: some View {
            VStack(spacing: 0) { inner }.environment(\.axoTabs, AxoTabs.Context(value: $value))
        }
    }

    /// `<AxoDialog.TabList>`: `px-4 pb-2` around a full-width, equal-width track segmented control.
    public struct TabList<Inner: View>: View {
        let inner: Inner
        @Environment(\.axoTabs) var context
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            ExperimentalAxoBaseSegmentedControl.Root(value: context.map { .single($0.value.wrappedValue) } ?? .none, variant: .track,
                                                     width: .full, itemWidth: .equal) { inner }
                .accessibilityElement(children: .contain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    /// `<AxoDialog.Tab>`
    public typealias Tab = AxoTabs.Trigger

    /// `<AxoDialog.TabContent>`: shown only for the selected tab.
    public typealias TabContent = AxoTabs.Content

    /// `<AxoDialog.Body>`: scrolls beyond `maxHeight`; inline padding inside the thin-scrollbar
    /// gutters, block padding 2px next to a header/footer.
    public struct Body<Inner: View>: View {
        let padding: BodyPadding
        let maxHeight: CGFloat
        /// `forceMaxHeight`: min-height = maxHeight.
        let forceMaxHeight: Bool
        let inner: Inner
        @Environment(\.axoDialogParts) var parts
        public init(padding: BodyPadding = .lg, maxHeight: CGFloat = 440, forceMaxHeight: Bool = false, @ViewBuilder content: () -> Inner) {
            self.padding = padding
            self.maxHeight = maxHeight
            self.forceMaxHeight = forceMaxHeight
            inner = content()
        }
        func content(_ g: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 0) { inner }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, g + padding.value)
                .padding(.top, parts.header ? 2 : padding.value)
                .padding(.bottom, parts.footer ? 2 : padding.value)
        }

        public var body: some View {
            // `scrollbar-gutter: stable both-edges` with the thin overlay scrollbar takes no
            // room: the captures of scrolling bodies (AxoDialog LongContent,
            // NewlyCreatedGroupInvitedContactsDialog ManyContacts) keep the plain padding.
            HeightLimited(maxHeight: maxHeight) {
                content(0)
                AxoScrollContainer { content(0) }
            }
            .frame(minHeight: forceMaxHeight ? maxHeight : nil, alignment: .top)
        }
    }

    /// Vertical scroll view; in static rendering, the content clipped at offset 0.
    struct AxoScrollContainer<Inner: View>: View {
        let inner: Inner
        @Environment(\.axoStaticRendering) var isStatic
        init(@ViewBuilder content: () -> Inner) { inner = content() }
        var body: some View {
            Group {
                if isStatic {
                    TopAligned { inner }.clipShape(Rectangle())
                } else {
                    ScrollView { inner }.scrollIndicators(.automatic)
                }
            }
            .axoPopperClip()
        }
    }

    /// Takes the proposed size; places its child at the top with the child's own height.
    struct TopAligned: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let child = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
            return CGSize(width: proposal.width ?? child.width, height: proposal.height ?? child.height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for s in subviews {
                let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: h))
            }
        }
    }

    /// Sizes itself to the content's height up to `maxHeight` (subview 0 is the measuring
    /// copy, never shown; subview 1, the scroll view, is placed at that height).
    struct HeightLimited: Layout {
        let maxHeight: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let h = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height
            return CGSize(width: proposal.width ?? subviews[0].sizeThatFits(.unspecified).width, height: min(h, maxHeight))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let fits = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height <= maxHeight
            let shown = subviews.count > 2 && !fits ? 2 : 1
            for (i, s) in subviews.enumerated() {
                let off = CGPoint(x: bounds.minX - 100_000, y: bounds.minY)
                if i == shown {
                    s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
                } else {
                    s.place(at: off, proposal: ProposedViewSize(width: bounds.width, height: i == 0 ? nil : bounds.height))
                }
            }
        }
    }

    /// `<AxoDialog.Description>` / story paragraphs: the panel's type-body-medium text-secondary.
    public struct Description: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View { CSSText(text, type: .bodyMedium) }
    }

    /// `<AxoDialog.Footer>`: flex flex-wrap items-center gap-x-2 gap-y-3 px-4 pt-2.5 pb-4.
    public struct Footer<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            CSSFlex(.row, wrap: true, gap: 8, crossGap: 12, align: .center) { inner }
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 16, trailing: 16))
        }
    }

    /// `<AxoDialog.FooterContent>`: px-2, basis min-content, min-width min(20ch, size), grows.
    public struct FooterContent: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View {
            let style = CSSTextStyle(.bodyMedium)
            let maxContent = CSSTextLayout.make(text, style, wrap: .nowrap, maxWidth: nil).width
            // basis-[min-content] min-w-[calc-size(fit-content, min(20ch, size))] grow
            CSSText(text, type: .bodyMedium, color: .labelPrimary)
                .padding(.horizontal, 8)
                .flexItem(grow: 1, basis: 16 + CSSTextLayout.minContentWidth(text, style),
                          minMain: 16 + min(20 * CSSTextLayout.ch(style), maxContent))
        }
    }

    /// `<AxoDialog.Actions>`: actions aligned to the end (`fit`) or filling the footer.
    public struct Actions<Inner: View>: View {
        public enum Width: Sendable { case fill, fit }
        let width: Width
        let inner: Inner
        public init(width: Width = .fit, @ViewBuilder content: () -> Inner) {
            self.width = width
            inner = content()
        }
        public var body: some View {
            if width == .fit {
                // <div class="ms-auto">: content-sized, pushed to the end of the footer line.
                AxoButton.Group(justify: .end) { inner.environment(\.axoButtonMinWidthFit, true) }.flexItem(autoMarginStart: true)
            } else {
                AxoButton.Group(justify: .center) { inner.environment(\.axoButtonMinWidthFit, true) }.flexItem(grow: 1)
            }
        }
    }

    /// `<AxoDialog.Action>`: md button that grows within the actions row.
    public struct Action: View {
        let label: String
        let variant: ActionVariant
        let symbol: AxoSymbol.Name?
        let arrow: AxoButton.Arrow?
        let pending: Bool
        let disabled: Bool
        let autoFocus: Bool
        let action: () -> Void
        public init(_ label: String, variant: ActionVariant, symbol: AxoSymbol.Name? = nil, arrow: AxoButton.Arrow? = nil, pending: Bool = false,
                    disabled: Bool = false, autoFocus: Bool = false, action: @escaping () -> Void) {
            self.autoFocus = autoFocus
            self.label = label
            self.variant = variant
            self.symbol = symbol
            self.arrow = arrow
            self.pending = pending
            self.disabled = disabled
            self.action = action
        }
        public var body: some View {
            AxoButton.Root(label, variant: variant.button, size: .md, width: .grow, symbol: symbol, arrow: arrow, pending: pending, disabled: disabled,
                           autoFocus: autoFocus, action: action)
        }
    }

    /// `<AxoDialog.IconAction>`
    public struct IconAction: View {
        let label: String
        let variant: IconActionVariant
        let symbol: AxoSymbol.Name
        let disabled: Bool
        let action: () -> Void
        public init(label: String, variant: IconActionVariant, symbol: AxoSymbol.Name, disabled: Bool = false, action: @escaping () -> Void) {
            self.label = label
            self.variant = variant
            self.symbol = symbol
            self.disabled = disabled
            self.action = action
        }
        public var body: some View {
            AxoIconButton.Root(label: label, variant: variant.button, size: .md, symbol: symbol, disabled: disabled, action: action)
        }
    }
}

extension ContainerValues {
    @Entry var axoDialogHeaderSlot: AxoDialog.HeaderSlot = .title
}

extension EnvironmentValues {
    @Entry var axoDialogCloseTakesFocus: Bool = true
    @Entry var axoDialogHeaderFloating: Bool = false

    var axoDialogParts: AxoDialog.Parts {
        get { self[AxoDialog.PartsKey.self] }
        set { self[AxoDialog.PartsKey.self] = newValue }
    }
}
