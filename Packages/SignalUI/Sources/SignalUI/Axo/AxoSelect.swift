// Port of ts/axo/AxoSelect.dom.tsx (Radix Select): a trigger button showing the selected
// option (or a placeholder) that opens a listbox of options, grouped and separated.
//
// SwiftUI structure: `Root` lays out only its `Trigger`; its `Content` is kept in the tree
// unseen (so `ItemText`s can report the labels the trigger shows). While open, a hidden
// measuring copy reports where the selected item and its text sit, and the content floats
// on the popper layer (upstream: a portal) item-aligned as Radix does: the selected item's
// text over the trigger's value, the item's middle on the trigger's middle. Opening
// highlights the selected item (with the focus ring when opened from the keyboard).

import CoreText
import SwiftUI

public enum AxoSelect {
    // MARK: Context

    struct Context {
        var selection: Binding<String?>
        var label: String?
        var disabled: Bool
        var open: Binding<Bool>
        var labels: [String: String]
        /// The highlighted (focused) item, and whether focus is visible (keyboard).
        var highlighted: String? = nil
        var focusVisible = false
        var highlight: @MainActor @Sendable (String?) -> Void = { _ in }

        var value: String? { selection.wrappedValue }
        func select(_ v: String) {
            selection.wrappedValue = v
            open.wrappedValue = false
        }
    }

    enum Placement { case hidden, measure, popup }

    /// Geometry reported by the measuring copy of the content and by the trigger.
    struct Measure {
        var content: Anchor<CGRect>?
        var dropdown = false
        var items: [(value: String, selected: Bool, item: Anchor<CGRect>, text: Anchor<CGRect>)] = []
        var triggerValue: Anchor<CGRect>?
    }

    struct MeasureKey: PreferenceKey {
        static var defaultValue: Measure { Measure() }
        static func reduce(value: inout Measure, nextValue: () -> Measure) {
            let n = nextValue()
            value.content = value.content ?? n.content
            value.dropdown = value.dropdown || n.dropdown
            value.items += n.items
            value.triggerValue = value.triggerValue ?? n.triggerValue
        }
    }

    struct ContentMinWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
    struct OpenWithKeyboardKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }

    /// Reports no size; its child is laid out unconstrained at the origin (a measuring copy).
    struct ZeroSize: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { .zero }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for s in subviews { s.place(at: bounds.origin, proposal: .unspecified) }
        }
    }

    struct ContextKey: EnvironmentKey { static let defaultValue: Context? = nil }
    struct PlacementKey: EnvironmentKey { static let defaultValue: Placement = .hidden }
    struct ItemValueKey: EnvironmentKey { static let defaultValue: String? = nil }

    /// value → ItemText, reported by every item.
    struct ItemTextsKey: PreferenceKey {
        static let defaultValue: [String: String] = [:]
        static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
            value.merge(nextValue()) { a, _ in a }
        }
    }

    // MARK: <AxoSelect.Root>

    /// `<AxoSelect.Root>`: should contain a `Trigger` and a `Content`.
    public struct Root<Content: View>: View {
        let label: String?
        let disabled: Bool
        @Binding var value: String?
        let content: Content
        let externalOpen: Binding<Bool>?
        @State private var internalOpen = false
        @State private var labels: [String: String] = [:]
        @State private var highlighted: String?
        @State private var focusVisible: Bool
        @State private var id = UUID().uuidString

        /// - Parameters:
        ///   - isOpen: controls the open state (default: internal).
        ///   - openedWithKeyboard: an initially open select shows the highlighted item's focus ring.
        public init(label: String?, value: Binding<String?>, disabled: Bool = false, isOpen: Binding<Bool>? = nil,
                    openedWithKeyboard: Bool = false, @ViewBuilder content: () -> Content) {
            self.label = label
            self.disabled = disabled
            self._value = value
            self.externalOpen = isOpen
            self._focusVisible = State(initialValue: openedWithKeyboard)
            self.content = content()
        }

        var isOpen: Bool { externalOpen?.wrappedValue ?? internalOpen }

        func setOpen(_ open: Bool, keyboard: Bool = false) {
            let open = open && !disabled
            if open { focusVisible = keyboard } else { highlighted = nil }
            if let externalOpen { externalOpen.wrappedValue = open } else { internalOpen = open }
        }

        public var body: some View {
            var context = Context(selection: $value, label: label, disabled: disabled,
                                  open: Binding(get: { isOpen }, set: { setOpen($0) }), labels: labels)
            // Radix focuses the selected item when the content opens.
            context.highlighted = highlighted ?? value
            context.focusVisible = focusVisible
            context.highlight = { highlighted = $0 }
            let openWithKeyboard: @MainActor @Sendable () -> Void = { setOpen(true, keyboard: true) }
            return ZStack(alignment: .topLeading) {
                content
                if isOpen {
                    ZeroSize { content.environment(\.axoSelectPlacement, .measure) }.hidden().accessibilityHidden(true)
                }
            }
            .onPreferenceChange(ItemTextsKey.self) { labels = $0 }
            .overlayPreferenceValue(MeasureKey.self) { m in
                GeometryReader { g in
                    let (placement, minWidth) = Self.placement(m, g)
                    Color.clear
                        .axoPopper(id: id, isPresented: isOpen, placement: placement, dismiss: { setOpen(false) }) {
                            content.environment(\.axoSelectPlacement, .popup)
                                .environment(\.axoSelect, context)
                                .environment(\.axoSelectContentMinWidth, minWidth)
                        }
                }
            }
            .environment(\.axoSelect, context)
            .environment(\.axoSelectOpenWithKeyboard, openWithKeyboard)
        }

        /// `SelectItemAlignedPosition` (or the dropdown's popper placement) from the measured
        /// geometry, and the content's min width (the trigger's width plus how far left of it
        /// the content starts).
        static func placement(_ m: Measure, _ g: GeometryProxy) -> (AxoPopper.Placement, CGFloat) {
            if m.dropdown {
                return (AxoPopper.Placement(side: .bottom, align: .start, sideOffset: 8, collisionPadding: 6), 0)
            }
            guard let c = m.content, let item = m.items.first(where: \.selected) ?? m.items.first else {
                return (AxoPopper.Placement(side: .bottom, align: .start), 0)
            }
            let content = g[c], itemRect = g[item.item], textRect = g[item.text]
            let valueLeft = m.triggerValue.map { g[$0].minX } ?? 12
            let offset = CGPoint(x: valueLeft - (textRect.minX - content.minX), y: g.size.height / 2 - (itemRect.midY - content.minY))
            var p = AxoPopper.Placement()
            p.itemAligned = offset
            return (p, g.size.width - offset.x)
        }
    }

    // MARK: <AxoSelect.Trigger>

    /// Visual style of the trigger button.
    public enum TriggerVariant: String, CaseIterable, Sendable { case `default`, elevated, implied }
    /// Width of the trigger button.
    public enum TriggerWidth: String, CaseIterable, Sendable { case fit, full }
    /// When the dropdown chevron is shown.
    public enum TriggerChevron: String, CaseIterable, Sendable {
        case always
        case onHover = "on-hover"
    }

    /// `<AxoSelect.Trigger>`: `inline-flex items-center rounded-full type-body-medium
    /// font-medium text-primary` (`disabled:text-disabled`), the value truncating in
    /// `flex min-w-0 flex-1 py-[5px]`, then a 14px chevron.
    public struct Trigger: View {
        let variant: TriggerVariant
        let width: TriggerWidth
        let chevron: TriggerChevron
        let placeholder: String?
        let custom: AnyView?
        @Environment(\.axoSelect) var context
        @Environment(\.axoSelectPlacement) var placement
        @Environment(\.axoSelectOpenWithKeyboard) var openWithKeyboard
        @Environment(\.axoAnimationsDisabled) var animationsDisabled
        @State private var hovered = false
        @FocusState private var focused: Bool

        public init(variant: TriggerVariant = .default, width: TriggerWidth = .fit, chevron: TriggerChevron = .always, placeholder: String?) {
            self.variant = variant
            self.width = width
            self.chevron = chevron
            self.placeholder = placeholder
            self.custom = nil
        }

        /// With custom rendering of the selected value.
        public init(variant: TriggerVariant = .default, width: TriggerWidth = .fit, chevron: TriggerChevron = .always, placeholder: String?,
                    @ViewBuilder value: () -> some View) {
            self.variant = variant
            self.width = width
            self.chevron = chevron
            self.placeholder = placeholder
            self.custom = AnyView(value())
        }

        var text: String {
            if let v = context?.value, let label = context?.labels[v] { return label }
            let p = placeholder ?? ""
            return p.isEmpty ? "\u{00A0}" : p
        }

        public var body: some View {
            if placement == .hidden { trigger }
        }

        var trigger: some View {
            let disabled = context?.disabled ?? false
            let open = context?.open.wrappedValue ?? false
            // on-hover: the chevron fades in and the value's end fades out while hovered, focused or open.
            let revealed = chevron == .always || (!disabled && (hovered || focused)) || open
            return Button {
                context?.open.wrappedValue = true
            } label: {
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        valueView
                            .anchorPreference(key: MeasureKey.self, value: .bounds) { Measure(triggerValue: $0) }
                            .padding(.vertical, 5)
                            .padding(.leading, 12)
                            .padding(.trailing, chevron == .onHover ? 12 : 0)
                            .frame(maxWidth: width == .full ? .infinity : nil, alignment: .leading)
                            .layoutPriority(-1)
                            .mask { if chevron == .onHover { TriggerMask(revealed: revealed) } else { Rectangle() } }
                        if chevron == .always {
                            chevronIcon.padding(.leading, 8).padding(.trailing, 10)
                        }
                    }
                    if chevron == .onHover {
                        // absolute inset-y-0 inset-e-0 w-9.5 flex items-center justify-end pe-2
                        AxoSymbol.Icon("chevron-down", size: 14, label: nil)
                            .padding(.trailing, 8)
                            .frame(width: 38, alignment: .trailing)
                            .opacity(revealed ? 1 : 0)
                    }
                }
                .cssTextColor(disabled ? .labelDisabled : .labelPrimary)
                .animation(animationsDisabled ? nil : .easeInOut(duration: 0.15), value: revealed)
            }
            .buttonStyle(TriggerStyle(variant: variant, disabled: disabled, hovered: hovered))
            .disabled(disabled)
            .focused($focused)
            .onKeyPress(keys: [.space, .return, .downArrow, .upArrow]) { _ in
                openWithKeyboard?()
                return .handled
            }
            .onHover { hovered = $0 }
            .frame(maxWidth: width == .full ? .infinity : nil, alignment: .leading)
            .accessibilityLabel(context?.label ?? "")
            .accessibilityValue(text)
        }

        @ViewBuilder var valueView: some View {
            if let custom, context?.value != nil {
                custom
            } else {
                // AxoBaseMenu.ItemText: flex-auto grow-0 truncate
                CSSText(text, type: AxoType.bodyMedium.weight(500), wrap: .truncate)
            }
        }

        /// `<Select.Icon className="ps-2 pe-2.5">`: an 18px line box (body-medium) whose 14px
        /// inline-flex icon sits on the text baseline.
        var chevronIcon: some View {
            AxoSymbol.Icon("chevron-down", size: 14, label: nil)
                .padding(.top, AxoSelect.baselineOffset(text: AxoType.bodyMedium.weight(500), iconSize: 14))
                .frame(height: 18, alignment: .top)
        }
    }

    /// Top of a `size`px icon (line-height 1) baseline-aligned in a line box of `text`.
    static func baselineOffset(text: AxoType, iconSize: CGFloat) -> CGFloat {
        let t = CSSTextStyle(text).ctFont
        let tAscent = CTFontGetAscent(t), tDescent = CTFontGetDescent(t)
        let textBaseline = (text.lineHeight - (tAscent + tDescent)) / 2 + tAscent
        let s = AxoSymbol.style(size: iconSize, weight: 400).ctFont
        let sAscent = CTFontGetAscent(s), sDescent = CTFontGetDescent(s)
        let iconBaseline = (iconSize - (sAscent + sDescent)) / 2 + sAscent
        return textBaseline - iconBaseline
    }

    /// `mask-[linear-gradient(to_left, var(--axo-select-trigger-mask-start) 19px, black 38px)]`:
    /// opaque at rest; while revealed the last 19px are hidden and the 19px before fade in.
    struct TriggerMask: View {
        let revealed: Bool
        var body: some View {
            let end = Color.black.opacity(revealed ? 0 : 1)
            HStack(spacing: 0) {
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, end], startPoint: .leading, endPoint: .trailing).frame(width: 19)
                Rectangle().fill(end).frame(width: 19)
            }
        }
    }

    struct TriggerStyle: ButtonStyle {
        let variant: TriggerVariant
        let disabled: Bool
        let hovered: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed && !disabled
            let shape = Capsule()
            return configuration.label
                .background {
                    switch variant {
                    case .default: shape.fill(pressed ? AxoColor.fillPrimaryPressed : AxoColor.fillPrimary)
                    case .elevated:
                        // bg-material-tertiary backdrop-blur-thin shadow-elevation-1
                        shape.fill(pressed ? AxoColor.materialTertiaryPressed : AxoColor.materialTertiary)
                            .axoShadow(.shadowElevation1, in: shape)
                    case .implied:
                        if pressed { shape.fill(AxoColor.fillPrimaryPressed) } else if hovered && !disabled { shape.fill(AxoColor.fillPrimary) }
                    }
                }
                .contentShape(shape)
        }
    }

    // MARK: <AxoSelect.Content>

    /// Positioning strategy for the popup.
    public enum ContentPosition: String, Sendable {
        case itemAligned = "item-aligned"
        case dropdown
    }

    /// `<AxoSelect.Content>`: `min-w-[200px] max-w-[300px] curved-xl bg-material-tertiary
    /// shadow-elevation-3`, a `p-1.5` column of groups, items and separators.
    public struct Content<Body: View>: View {
        let position: ContentPosition
        let content: Body
        @Environment(\.axoSelectPlacement) var placement

        public init(position: ContentPosition = .itemAligned, @ViewBuilder content: () -> Body) {
            self.position = position
            self.content = content()
        }

        public var body: some View {
            switch placement {
            case .hidden:
                // Unseen: only reports item labels for the trigger.
                VStack(alignment: .leading, spacing: 0) { content }
                    .hidden()
                    .frame(width: 0, height: 0)
                    .clipped()
                    .accessibilityHidden(true)
            case .measure:
                // (merged with the items' reports from inside)
                panel.transformAnchorPreference(key: MeasureKey.self, value: .bounds) { m, anchor in
                    m.content = anchor
                    m.dropdown = position == .dropdown
                }
            case .popup:
                panel.accessibilityElement(children: .contain)
            }
        }

        @Environment(\.axoSelectContentMinWidth) var minWidth

        var panel: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(6)
                .frame(minWidth: max(200, minWidth), maxWidth: max(300, minWidth), alignment: .leading)
                .fixedSize()
                .background(SuperellipseRect.curved(12).fill(AxoColor.materialTertiary))
                .axoShadow(.shadowElevation3, in: SuperellipseRect.curved(12))
        }
    }

    // MARK: <AxoSelect.Item>

    /// `<AxoSelect.Item>`: `truncate p-1.5 curved-md type-body-medium text-primary`
    /// (`data-highlighted:bg-primary-pressed`, `data-disabled:text-disabled`): a 14px check
    /// column (`w-3.5 me-1.5`) then the optional symbol (`me-2`) and the content.
    public struct Item<Body: View>: View {
        let value: String
        let disabled: Bool
        let textValue: String?
        let symbol: AxoSymbol.Name?
        let content: Body
        @Environment(\.axoSelect) var context
        @State private var hovered = false

        public init(value: String, disabled: Bool = false, textValue: String? = nil, symbol: AxoSymbol.Name? = nil,
                    @ViewBuilder content: () -> Body) {
            self.value = value
            self.disabled = disabled
            self.textValue = textValue
            self.symbol = symbol
            self.content = content()
        }

        @Environment(\.axoSelectPlacement) var placement

        public var body: some View {
            let selected = context?.value == value
            let highlighted = !disabled && context?.highlighted == value
            let shape = SuperellipseRect.curved(6)
            Button {
                if !disabled { context?.select(value) }
            } label: {
                HStack(spacing: 0) {
                    ZStack {
                        if selected { AxoSymbol.Icon("check", size: 14, label: nil) }
                    }
                    .frame(width: 14)
                    .padding(.trailing, 6)
                    HStack(spacing: 0) {
                        if let symbol { AxoSymbol.Icon(symbol, size: 16, label: nil).padding(.trailing, 8) }
                        content.anchorPreference(key: MeasureKey.self, value: .bounds) { text in
                            placement == .measure ? Measure(items: [(value, selected, text, text)]) : Measure()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .cssTextColor(disabled ? .labelDisabled : .labelPrimary)
                // data-highlighted: bg-primary-pressed; focus-visible: the focus ring.
                .background { if highlighted { shape.fill(AxoColor.fillPrimaryPressed) } }
                .axoFocusRing(highlighted && (context?.focusVisible ?? false), in: shape)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .onHover { inside in
                hovered = inside
                if inside && !disabled { context?.highlight(value) }
            }
            .environment(\.axoSelectItemValue, value)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(textValue ?? "")
        }
    }

    /// `<AxoSelect.ItemText>`: the item's label, also shown in the trigger when selected.
    public struct ItemText: View {
        let text: String
        @Environment(\.axoSelectItemValue) var itemValue

        public init(_ text: String) { self.text = text }

        public var body: some View {
            CSSText(text, type: .bodyMedium, wrap: .truncate)
                .preference(key: ItemTextsKey.self, value: itemValue.map { [$0: text] } ?? [:])
        }
    }

    /// `<AxoSelect.ItemBadge>`: a small badge at the item's end (`ms-[5px]`).
    public struct ItemBadge: View {
        let variant: AxoBadge.Variant
        let value: AxoBadge.Value
        let max: Int?
        let label: String?

        public init(variant: AxoBadge.Variant, value: AxoBadge.Value, max: Int?, label: String?) {
            self.variant = variant
            self.value = value
            self.max = max
            self.label = label
        }

        public var body: some View {
            AxoBadge.Root(variant: variant, size: .sm, value: value, max: max, label: label, letterSpacing: AxoType.bodyMedium.tracking * 13)
                .padding(.leading, 5)
        }
    }

    /// `<AxoSelect.Group>`
    public struct Group<Body: View>: View {
        let content: Body
        public init(@ViewBuilder content: () -> Body) { self.content = content() }
        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }.accessibilityElement(children: .contain)
        }
    }

    /// `<AxoSelect.Label>`: `truncate p-1.5 type-body-small text-secondary`, in the content column.
    public struct Label: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View {
            CSSText(text, type: .bodySmall, wrap: .truncate, color: .labelSecondary)
                .padding(.leading, 20)
                .padding(6)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// `<AxoSelect.Separator>`: `my-1 border-t-[0.5px] border-primary`.
    public struct Separator: View {
        public init() {}
        public var body: some View {
            Rectangle().fill(AxoColor.borderPrimary).frame(height: 0.5).padding(.vertical, 4)
        }
    }
}

extension EnvironmentValues {
    var axoSelect: AxoSelect.Context? {
        get { self[AxoSelect.ContextKey.self] }
        set { self[AxoSelect.ContextKey.self] = newValue }
    }
    var axoSelectPlacement: AxoSelect.Placement {
        get { self[AxoSelect.PlacementKey.self] }
        set { self[AxoSelect.PlacementKey.self] = newValue }
    }
    var axoSelectContentMinWidth: CGFloat {
        get { self[AxoSelect.ContentMinWidthKey.self] }
        set { self[AxoSelect.ContentMinWidthKey.self] = newValue }
    }
    var axoSelectOpenWithKeyboard: (@MainActor @Sendable () -> Void)? {
        get { self[AxoSelect.OpenWithKeyboardKey.self] }
        set { self[AxoSelect.OpenWithKeyboardKey.self] = newValue }
    }
    var axoSelectItemValue: String? {
        get { self[AxoSelect.ItemValueKey.self] }
        set { self[AxoSelect.ItemValueKey.self] = newValue }
    }
}
