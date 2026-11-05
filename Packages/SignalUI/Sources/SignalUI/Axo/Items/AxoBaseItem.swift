// Port of ts/axo/items/_AxoBaseItem.dom.tsx + _AxoBaseItem.css: the list item every
// Axo list is built from.
//
//   <Group>                 grid [leading min-content] [content auto], min-w-70
//     <Root>                subgrid row (px-3, py-2 | py-1.5), hover/press fill
//       <Leading>           pe-3, self-start, centred within max-h 38px
//       <Content>           grid of Label / Value / Description / Accessory / Trailing
//
// CSS subgrid is ported by flattening: `Root`'s body is its background (a marker) followed
// by its own children, so `Group`'s layout sees every item's Leading and Content directly
// and can size the shared leading column like the grid does. `Content` is a layout over
// its parts and switches to the stacked template when the item would overflow the group
// (upstream measures that with a ResizeObserver: item.clientWidth > group.clientWidth).

import CoreText
import SwiftUI

public enum AxoBaseItem {
    public enum Spacing: String, Sendable, CaseIterable {
        case md, sm
        var paddingY: CGFloat { self == .md ? 8 : 6 }
    }

    public enum Variant: String, Sendable, CaseIterable { case secondary, destructive }

    /// `axo-item-centering-to-max-height`: --axo-leading-body-medium + --axo-leading-body-small + 2.
    static let centeringMaxHeight: CGFloat = 38
    /// px-3 of `.axo-item-root-inner`
    static let paddingX: CGFloat = 12
    /// `min-w-70` of `.axo-item-group`
    static let groupMinWidth: CGFloat = 280
    /// `min-w-30` of the label / description column
    static let labelMinWidth: CGFloat = 120

    /// Item state inherited by the parts (disabled / destructive colours).
    struct ItemState: Sendable, Hashable {
        var variant: Variant = .secondary
        var disabled = false
        var forceStacked = false

        var iconColor: AxoColor { labelColor }
        var labelColor: AxoColor {
            switch (variant, disabled) {
            case (.destructive, true): .labelDestructiveDisabled
            case (.destructive, false): .labelDestructive
            case (.secondary, true): .labelDisabled
            case (.secondary, false): .labelPrimary
            }
        }
        var secondaryColor: AxoColor { disabled ? .labelDisabled : .labelSecondary }
        var arrowColor: AxoColor { disabled ? .labelDisabled : .labelPlaceholder }
    }

    struct ItemStateKey: EnvironmentKey { static let defaultValue = ItemState() }
    struct SpacingKey: EnvironmentKey { static let defaultValue = Spacing.md }
    struct TriggerKey: EnvironmentKey { static let defaultValue: TriggerBox? = nil }

    /// The item's `HiddenTrigger`, registered with its `Root` (upstream: an absolutely
    /// positioned button under the accessories that covers the whole item).
    @MainActor @Observable final class TriggerBox {
        var label: String?
        var action: (() -> Void)?
        init() {}
    }

    /// What a subview of `Group` / `Content` is.
    enum Part: Equatable, Sendable {
        case none
        // Group level
        case root
        case leading(centerToFullHeight: Bool)
        /// An `Icon` placed straight in the root, outside `Leading` (WhileMutedSettings): a
        /// grid item with no end padding, at the row's top.
        case bareIcon
        case content
        // Content level
        case label, value, description, trigger, trailing
        case accessory(centerToFullHeight: Bool)
    }

    struct PartKey: LayoutValueKey { static let defaultValue = Part.none }
}

extension EnvironmentValues {
    var axoItemState: AxoBaseItem.ItemState {
        get { self[AxoBaseItem.ItemStateKey.self] }
        set { self[AxoBaseItem.ItemStateKey.self] = newValue }
    }
    var axoItemSpacing: AxoBaseItem.Spacing {
        get { self[AxoBaseItem.SpacingKey.self] }
        set { self[AxoBaseItem.SpacingKey.self] = newValue }
    }
    var axoItemTrigger: AxoBaseItem.TriggerBox? {
        get { self[AxoBaseItem.TriggerKey.self] }
        set { self[AxoBaseItem.TriggerKey.self] = newValue }
    }
}

extension View {
    func axoItemPart(_ part: AxoBaseItem.Part) -> some View { layoutValue(key: AxoBaseItem.PartKey.self, value: part) }
}

// MARK: - <AxoBaseItem.Group>

extension AxoBaseItem {
    /// `<AxoBaseItem.Group>`
    public struct Group<Content: View>: View {
        let spacing: Spacing
        let content: Content
        public init(spacing: Spacing, @ViewBuilder content: () -> Content) {
            self.spacing = spacing
            self.content = content()
        }
        public var body: some View {
            GroupLayout(spacing: spacing) { content }
                .environment(\.axoItemSpacing, spacing)
        }
    }

    /// The `.axo-item-group` grid with each item's row as a subgrid.
    struct GroupLayout: Layout {
        let spacing: Spacing

        struct Item {
            var root: Int
            var leading: Int?
            var content: Int?
        }

        struct Row {
            var item: Item
            var height: CGFloat          // outer row height (with py)
            var inner: CGFloat           // content row height
            var leadingSize: CGSize
            var centerLeading: Bool
        }

        func items(_ subviews: Subviews) -> [Item] {
            var out: [Item] = []
            for i in subviews.indices {
                switch subviews[i][PartKey.self] {
                case .root: out.append(Item(root: i))
                case .leading, .bareIcon: if !out.isEmpty { out[out.count - 1].leading = i }
                case .content: if !out.isEmpty { out[out.count - 1].content = i }
                default: break
                }
            }
            return out
        }

        func leadingColumn(_ subviews: Subviews, _ items: [Item]) -> CGFloat {
            let widths = items.compactMap { item in
                item.leading.map {
                    subviews[$0].sizeThatFits(.unspecified).width + (subviews[$0][PartKey.self] == .bareIcon ? 0 : AxoBaseItem.paddingX)
                }
            }
            return widths.max() ?? 0
        }

        func rows(_ subviews: Subviews, width: CGFloat) -> (leadingCol: CGFloat, rows: [Row]) {
            let items = items(subviews)
            let leadingCol = leadingColumn(subviews, items)
            let contentWidth = max(0, width - 2 * AxoBaseItem.paddingX - leadingCol)
            let rows = items.map { item -> Row in
                let lead = item.leading.map { subviews[$0].sizeThatFits(.unspecified) } ?? .zero
                let center: Bool = item.leading.map {
                    if case .leading(let c) = subviews[$0][PartKey.self] { return c }
                    return false
                } ?? false
                let content = item.content.map { subviews[$0].sizeThatFits(ProposedViewSize(width: contentWidth, height: nil)).height } ?? 0
                let inner = max(lead.height, content)
                return Row(item: item, height: inner + 2 * spacing.paddingY, inner: inner, leadingSize: lead, centerLeading: center)
            }
            return (leadingCol, rows)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = max(AxoBaseItem.groupMinWidth, proposal.width ?? AxoBaseItem.groupMinWidth)
            let (_, rows) = rows(subviews, width: width)
            return CGSize(width: width, height: rows.map(\.height).reduce(0, +))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let (leadingCol, rows) = rows(subviews, width: bounds.width)
            let contentWidth = max(0, bounds.width - 2 * AxoBaseItem.paddingX - leadingCol)
            var y = bounds.minY
            for row in rows {
                subviews[row.item.root].place(at: CGPoint(x: bounds.minX, y: y),
                                              proposal: ProposedViewSize(width: bounds.width, height: row.height))
                let top = y + spacing.paddingY
                if let l = row.item.leading {
                    // self-start; h-stretch clamped to max-h 38 (unless centerToFullHeight), min-h-fit;
                    // flex items-center inside.
                    let box = subviews[l][PartKey.self] == .bareIcon ? row.leadingSize.height
                        : row.centerLeading ? row.inner
                        : max(row.leadingSize.height, min(row.inner, AxoBaseItem.centeringMaxHeight))
                    subviews[l].place(at: CGPoint(x: bounds.minX + AxoBaseItem.paddingX, y: top + (box - row.leadingSize.height) / 2),
                                      proposal: ProposedViewSize(row.leadingSize))
                }
                if let c = row.item.content {
                    subviews[c].place(at: CGPoint(x: bounds.minX + AxoBaseItem.paddingX + leadingCol, y: top),
                                      proposal: ProposedViewSize(width: contentWidth, height: row.inner))
                }
                y += row.height
            }
            for i in subviews.indices where subviews[i][PartKey.self] == .none {
                subviews[i].place(at: bounds.origin, proposal: .zero)
            }
        }
    }
}

// MARK: - <AxoBaseItem.Root>

extension AxoBaseItem {
    /// `<AxoBaseItem.Root>`. With `action` the whole item is the button (upstream `asChild`
    /// with a `<button>`); otherwise a `HiddenTrigger` inside makes it clickable.
    public struct Root<Content: View>: View {
        let variant: Variant
        let disabled: Bool
        let forceStackedLayout: Bool
        let action: (() -> Void)?
        let accessibilityLabel: String?
        let content: Content
        @State private var trigger = TriggerBox()

        public init(variant: Variant = .secondary, disabled: Bool = false, forceStackedLayout: Bool = false,
                    accessibilityLabel: String? = nil, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
            self.variant = variant
            self.disabled = disabled
            self.forceStackedLayout = forceStackedLayout
            self.action = action
            self.accessibilityLabel = accessibilityLabel
            self.content = content()
        }

        public var body: some View {
            RootBackground(trigger: trigger, action: action, disabled: disabled, label: accessibilityLabel)
                .axoItemPart(.root)
            content
                .environment(\.axoItemState, ItemState(variant: variant, disabled: disabled, forceStacked: forceStackedLayout))
                .environment(\.axoItemTrigger, trigger)
        }
    }

    /// `.axo-item-root-inner`'s fill (`group-data-hovered:bg-secondary`,
    /// `group-data-pressed:bg-secondary-pressed`) under the item's trigger button.
    struct RootBackground: View {
        let trigger: TriggerBox
        let action: (() -> Void)?
        let disabled: Bool
        let label: String?
        @State private var hovered = false
        @Environment(\.axoItemFocusVisible) var focusVisible

        var body: some View {
            let shape = SuperellipseRect.curved(AxoRadius.xl)
            rootButton(shape).axoFocusRing(focusVisible, in: shape)
        }

        @ViewBuilder func rootButton(_ shape: SuperellipseRect) -> some View {
            if let run = action ?? trigger.action {
                Button {
                    if !disabled { run() }
                } label: {
                    Color.clear.contentShape(shape)
                }
                .buttonStyle(RootButtonStyle(hovered: hovered && !disabled, disabled: disabled, shape: shape))
                .onHover { hovered = $0 }
                .accessibilityLabel(label ?? trigger.label ?? "")
            } else {
                Color.clear
            }
        }
    }

    struct RootButtonStyle: ButtonStyle {
        let hovered: Bool
        let disabled: Bool
        let shape: SuperellipseRect
        func makeBody(configuration: Configuration) -> some View {
            let fill: AxoColor? = disabled ? nil : configuration.isPressed ? .fillSecondaryPressed : hovered ? .fillSecondary : nil
            configuration.label.background { if let fill { shape.fill(fill) } }
        }
    }
}

// MARK: - Leading parts

extension AxoBaseItem {
    /// `<AxoBaseItem.Leading>`
    public struct Leading<Content: View>: View {
        let centerToFullHeight: Bool
        let content: Content
        public init(centerToFullHeight: Bool = false, @ViewBuilder content: () -> Content) {
            self.centerToFullHeight = centerToFullHeight
            self.content = content()
        }
        public var body: some View {
            HStack(spacing: 0) { content }          // flex items-center
                .axoItemPart(.leading(centerToFullHeight: centerToFullHeight))
        }
    }

    /// `<AxoBaseItem.Icon>`: an 18px `AxoSymbol.Icon` in an inline span. The span's line box
    /// is the inherited body text's (14px/20px Inter; 13px/18px inside a dialog panel), with the
    /// icon (`vertical-align: middle`: its centre half an x-height above the baseline) able to
    /// hang below it, as Blink lays it out (rounded ascent / descent, floored half-leading).
    public struct Icon: View {
        let symbol: AxoSymbol.Name
        @Environment(\.axoItemState) var state
        @Environment(\.axoInheritedTextSize) var inherited
        public init(symbol: AxoSymbol.Name) { self.symbol = symbol }

        /// (top of the icon, height of the span's line box) for the inherited text.
        static func metrics(size: CGFloat, lineHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
            let font = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: size, lineHeight: lineHeight).ctFont
            let a = CTFontGetAscent(font).rounded(), d = CTFontGetDescent(font).rounded()
            let baseline = ((lineHeight - (a + d)) / 2).rounded(.down) + a
            let top = baseline - CTFontGetXHeight(font) / 2 - 9
            let lineTop = min(0, top)
            return (top - lineTop, max(lineHeight, top + 18) - lineTop)
        }

        public var body: some View {
            let m = Self.metrics(size: inherited.size, lineHeight: inherited.lineHeight)
            AxoSymbol.Icon(symbol, size: 18, label: nil)
                .padding(.top, m.top)
                .padding(.bottom, m.height - 18 - m.top)
                .cssTextColor(state.iconColor)
                .allowsHitTesting(false)
                .axoItemPart(.bareIcon)     // inside Leading, the HStack's part wins
        }
    }

    /// `<AxoBaseItem.Checkbox>`
    public struct Checkbox: View {
        @Binding var checked: Bool
        let disabled: Bool
        public init(checked: Binding<Bool>, disabled: Bool = false) {
            _checked = checked
            self.disabled = disabled
        }
        public var body: some View { AxoCheckbox.Root(variant: .square, checked: $checked, disabled: disabled) }
    }

    public typealias IconAvatarSize = CGFloat   // upstream: 32 | 36 | 38 | 48

    /// `<AxoBaseItem.IconAvatar>`
    public struct IconAvatar: View {
        let size: IconAvatarSize
        let symbol: AxoSymbol.Name
        let color: String?
        public init(size: IconAvatarSize, symbol: AxoSymbol.Name, color: String? = nil) {
            self.size = size
            self.symbol = symbol
            self.color = color
        }
        public var body: some View {
            AxoAvatar.Root(size: size) {
                AxoAvatar.Content(label: nil) { AxoAvatar.Icon(symbol: symbol, color: color) }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - <AxoBaseItem.Content>

extension AxoBaseItem {
    /// `<AxoBaseItem.Content>`
    public struct Content<Parts: View>: View {
        let parts: Parts
        @Environment(\.axoItemState) var state
        public init(@ViewBuilder content: () -> Parts) { parts = content() }
        public var body: some View {
            ContentLayout(forceStacked: state.forceStacked) { parts }
                .axoItemPart(.content)
        }
    }

    /// `.axo-item-content`'s two grid templates:
    ///
    ///     'label       value accessory trailing' 1fr
    ///     'description value accessory trailing' min-content / auto min-content min-content min-content
    ///
    /// and, stacked (when the row's min-content would overflow the group):
    ///
    ///     'label trailing' 'value trailing' 'description trailing' 'accessory trailing' / auto min-content
    struct ContentLayout: Layout {
        let forceStacked: Bool

        struct Plan {
            var frames: [Int: CGRect] = [:]
            var height: CGFloat = 0
        }

        func find(_ subviews: Subviews, _ match: (Part) -> Bool) -> Int? {
            subviews.indices.first { match(subviews[$0][PartKey.self]) }
        }

        func plan(_ subviews: Subviews, width w: CGFloat, height: CGFloat?) -> Plan {
            let label = find(subviews) { $0 == .label }
            let value = find(subviews) { $0 == .value }
            let description = find(subviews) { $0 == .description }
            let trailing = find(subviews) { $0 == .trailing }
            let accessory = find(subviews) { if case .accessory = $0 { return true } else { return false } }
            let accessoryFull: Bool = accessory.map {
                if case .accessory(let c) = subviews[$0][PartKey.self] { return c }
                return false
            } ?? false

            func natural(_ i: Int?) -> CGSize { i.map { subviews[$0].sizeThatFits(.unspecified) } ?? .zero }
            func heightAt(_ i: Int?, _ width: CGFloat) -> CGFloat {
                i.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0
            }

            let v = natural(value), a = natural(accessory), t = natural(trailing)
            let valueCol = value != nil ? v.width + 12 : 0          // ms-3
            let accessoryCol = accessory != nil ? a.width + 12 : 0  // ms-3
            let trailingCol = trailing != nil ? t.width + 6 : 0     // ml-1.5
            var plan = Plan()

            let col1 = w - valueCol - accessoryCol - trailingCol
            if !forceStacked && col1 >= AxoBaseItem.labelMinWidth - 0.01 {
                let labelH = heightAt(label, col1)
                let descRow = description != nil ? heightAt(description, col1) + 2 : 0   // mt-0.5
                let spans = [value != nil ? v.height : 0, accessory != nil ? a.height : 0, trailing != nil ? t.height : 0]
                let natural = max(labelH, (spans.max() ?? 0) - descRow) + descRow
                let total = max(natural, height ?? 0)
                let row1 = total - descRow
                if let label {
                    let box = max(labelH, min(row1, AxoBaseItem.centeringMaxHeight))
                    plan.frames[label] = CGRect(x: 0, y: (box - labelH) / 2, width: col1, height: labelH)
                }
                if let description {
                    plan.frames[description] = CGRect(x: 0, y: row1 + 2, width: col1, height: descRow - 2)
                }
                func span(_ i: Int?, _ size: CGSize, x: CGFloat, full: Bool = false) {
                    guard let i else { return }
                    let box = full ? total : max(size.height, min(total, AxoBaseItem.centeringMaxHeight))
                    plan.frames[i] = CGRect(x: x, y: (box - size.height) / 2, width: size.width, height: size.height)
                }
                span(value, v, x: col1 + 12)
                span(accessory, a, x: col1 + valueCol + 12, full: accessoryFull)
                span(trailing, t, x: col1 + valueCol + accessoryCol + 6)
                plan.height = natural
            } else {
                let col = max(0, w - trailingCol)
                var y: CGFloat = 0
                if let label {
                    let h = heightAt(label, col)
                    plan.frames[label] = CGRect(x: 0, y: y, width: col, height: h)
                    y += h
                }
                if let value {
                    let h = heightAt(value, col)
                    plan.frames[value] = CGRect(x: 0, y: y, width: col, height: h)
                    y += h
                }
                if let description {
                    let h = heightAt(description, col)
                    plan.frames[description] = CGRect(x: 0, y: y + 2, width: col, height: h)
                    y += h + 2
                }
                if let accessory {
                    // mt-0.5 flex-col items-stretch -mx-1
                    let h = heightAt(accessory, col + 8)
                    plan.frames[accessory] = CGRect(x: -4, y: y + 2, width: col + 8, height: h)
                    y += h + 2
                }
                if let trailing {
                    let box = max(t.height, min(y, AxoBaseItem.centeringMaxHeight))
                    plan.frames[trailing] = CGRect(x: col + 6, y: (box - t.height) / 2, width: t.width, height: t.height)
                    y = max(y, t.height)
                }
                plan.height = y
            }
            return plan
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = proposal.width ?? AxoBaseItem.labelMinWidth
            // Grid items stretch to their row (align-self: normal): take a definite proposed height.
            let stretch = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
            return CGSize(width: w, height: max(stretch, plan(subviews, width: w, height: nil).height))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let plan = plan(subviews, width: bounds.width, height: bounds.height)
            for i in subviews.indices {
                if let f = plan.frames[i] {
                    subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
                } else {
                    subviews[i].place(at: bounds.origin, proposal: .zero)
                }
            }
        }
    }

    /// `<AxoBaseItem.Label>`: type-body-medium, text-primary; wraps (or `truncate`).
    public struct Label<Inner: View>: View {
        let inner: Inner
        @Environment(\.axoItemState) var state
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            inner
                .cssTextColor(state.labelColor)
                .allowsHitTesting(false)
                .axoItemPart(.label)
        }
    }

    /// `<AxoBaseItem.Value>`: type-body-medium, text-secondary, `text-nowrap` beside the label.
    public struct Value<Inner: View>: View {
        let inner: Inner
        @Environment(\.axoItemState) var state
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            inner
                .cssTextColor(state.secondaryColor)
                .allowsHitTesting(false)
                .axoItemPart(.value)
        }
    }

    /// `<AxoBaseItem.Description>`: type-body-small, text-secondary, mt-0.5.
    public struct Description<Inner: View>: View {
        let inner: Inner
        /// Content with controls of its own takes clicks (it sits above the item's trigger).
        let interactive: Bool
        @Environment(\.axoItemState) var state
        public init(interactive: Bool = false, @ViewBuilder content: () -> Inner) {
            self.interactive = interactive
            inner = content()
        }
        public var body: some View {
            inner
                .cssTextColor(state.secondaryColor)
                .allowsHitTesting(interactive)
                .axoItemPart(.description)
        }
    }

    /// `<AxoBaseItem.HiddenTrigger>`: makes the whole item clickable (see `Root`).
    public struct HiddenTrigger: View {
        let label: String?
        let action: () -> Void
        @Environment(\.axoItemTrigger) var trigger
        @Environment(\.axoItemState) var state
        public init(label: String? = nil, action: @escaping () -> Void) {
            self.label = label
            self.action = action
        }
        public var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    trigger?.label = label
                    trigger?.action = action
                }
                .onDisappear { trigger?.action = nil }
                .axoItemPart(.trigger)
        }
    }

    /// `<AxoBaseItem.DescribedBy>`: upstream adds the item's values and descriptions to the
    /// control's `aria-describedby`; SwiftUI controls read their surrounding labels, so this
    /// passes the control through.
    public struct DescribedBy<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View { inner }
    }

    /// `<AxoBaseItem.Accessory>`: flex items-center gap-1.5, ms-3.
    public struct Accessory<Inner: View>: View {
        let centerToFullHeight: Bool
        let inner: Inner
        public init(centerToFullHeight: Bool = false, @ViewBuilder content: () -> Inner) {
            self.centerToFullHeight = centerToFullHeight
            inner = content()
        }
        public var body: some View {
            CSSFlex(.row, gap: 6, align: .center) { inner }
                .axoItemPart(.accessory(centerToFullHeight: centerToFullHeight))
        }
    }

    public enum ActionVariant: String, Sendable, CaseIterable {
        case subtleSecondary = "subtle-secondary", strongAffirmative = "strong-affirmative", subtleDestructive = "subtle-destructive"
        var button: AxoButton.Variant {
            switch self {
            case .subtleSecondary: .subtleSecondary
            case .strongAffirmative: .strongAffirmative
            case .subtleDestructive: .subtleDestructive
            }
        }
    }

    /// `<AxoBaseItem.Action>`: an md `AxoButton`.
    public struct Action: View {
        let label: String
        let variant: ActionVariant
        let symbol: AxoSymbol.Name?
        let pending: Bool
        let action: () -> Void
        public init(_ label: String, variant: ActionVariant, symbol: AxoSymbol.Name? = nil, pending: Bool = false,
                    action: @escaping () -> Void = {}) {
            self.label = label
            self.variant = variant
            self.symbol = symbol
            self.pending = pending
            self.action = action
        }
        public var body: some View {
            AxoButton.Root(label, variant: variant.button, size: .md, symbol: symbol, pending: pending, action: action)
        }
    }

    public enum IconActionVariant: String, Sendable, CaseIterable {
        case impliedSecondary = "implied-secondary", subtleAffirmative = "subtle-affirmative", subtleDestructive = "subtle-destructive"
        var button: AxoIconButton.Variant {
            switch self {
            case .impliedSecondary: .impliedSecondary
            case .subtleAffirmative: .subtleAffirmative
            case .subtleDestructive: .subtleDestructive
            }
        }
    }

    /// `<AxoBaseItem.IconAction>`: an md `AxoIconButton`.
    public struct IconAction: View {
        let label: String
        let variant: IconActionVariant
        let symbol: AxoSymbol.Name
        let disabled: Bool
        let pending: Bool
        let tooltip: Bool
        let action: () -> Void
        public init(label: String, variant: IconActionVariant, symbol: AxoSymbol.Name, disabled: Bool = false, pending: Bool = false,
                    tooltip: Bool = true, action: @escaping () -> Void = {}) {
            self.label = label
            self.variant = variant
            self.symbol = symbol
            self.disabled = disabled
            self.pending = pending
            self.tooltip = tooltip
            self.action = action
        }
        public var body: some View {
            AxoIconButton.Root(label: label, tooltip: tooltip, variant: variant.button, size: .md, symbol: symbol, pending: pending,
                               disabled: disabled, action: action)
        }
    }

    /// `<AxoBaseItem.Trailing>`: flex items-center gap-1.5, ml-1.5.
    public struct Trailing<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            CSSFlex(.row, gap: 6, align: .center) { inner }
                .axoItemPart(.trailing)
        }
    }

    public enum ArrowKind: String, Sendable, CaseIterable {
        case next, externalLink = "external-link"
        var symbol: AxoSymbol.Name { self == .next ? "chevron-[end]" : "open" }
    }

    /// `<AxoBaseItem.Arrow>`: an inline glyph in a type-body-medium line (13px in an 18px
    /// line box, sitting on Inter's baseline), text-placeholder.
    public struct Arrow: View {
        let kind: ArrowKind
        @Environment(\.axoItemState) var state
        public init(kind: ArrowKind = .next) { self.kind = kind }
        public var body: some View {
            AxoSymbol.InlineGlyph(kind.symbol, size: 13, weight: 400)
                .padding(.top, 3)
                .padding(.bottom, 2)
                .cssTextColor(state.arrowColor)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Text

extension AxoBaseItem {
    /// Item text: a `CSSText` in a type preset, coloured by its part.
    public struct Text: View {
        let string: String
        let style: CSSTextStyle
        let wrap: CSSTextWrap
        public init(_ string: String, type: AxoType, wrap: CSSTextWrap = .wrap) {
            self.string = string
            style = CSSTextStyle(type)
            self.wrap = wrap
        }
        public init(_ string: String, style: CSSTextStyle, wrap: CSSTextWrap = .wrap) {
            self.string = string
            self.style = style
            self.wrap = wrap
        }
        public var body: some View { CSSText(string, style: style, wrap: wrap) }
    }
}

extension AxoBaseItem.Label where Inner == AxoBaseItem.Text {
    public init(_ text: String, truncate: Bool = false) {
        self.init { AxoBaseItem.Text(text, type: .bodyMedium, wrap: truncate ? .truncate : .wrap) }
    }
}

extension AxoBaseItem.Value where Inner == AxoBaseItem.Text {
    public init(_ text: String) {
        self.init { AxoBaseItem.Text(text, type: .bodyMedium) }
    }
}

extension AxoBaseItem.Description where Inner == AxoBaseItem.Text {
    public init(_ text: String, truncate: Bool = false) {
        self.init { AxoBaseItem.Text(text, type: .bodySmall, wrap: truncate ? .truncate : .wrap) }
    }
}

extension EnvironmentValues {
    /// The font size and line height inline item parts inherit (the body's 14px/20px; a
    /// dialog panel's type-body-medium 13px/18px).
    @Entry public var axoInheritedTextSize: (size: CGFloat, lineHeight: CGFloat) = (14, 20)
}

extension EnvironmentValues {
    /// The item's trigger shows its focus-visible ring (`axo-focus-ring` on the root), e.g. when
    /// a page focuses its first control on open.
    @Entry public var axoItemFocusVisible = false
}
