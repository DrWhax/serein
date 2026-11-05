// Port of ts/axo/fields/_AxoBaseField.dom.tsx + _AxoBaseField.css: the shared anatomy of
// AxoTextField, AxoSearchField, AxoPasswordField and AxoFieldGroup.
//
// Upstream's Root is a CSS grid
//   'leading textbox count trailing' min-content / min-content auto min-content min-content
//   'error   error   error trailing…'
// whose children pick their cell by class, and whose `:has()` rules hide parts depending
// on their siblings (a leading action hides the icon, a trailing action hides Clear, a
// pending loading indicator hides both …). SwiftUI views cannot inspect their siblings, so
// here the parts are values collected by a result builder (`FieldPartsBuilder`): `Root`
// sees the whole list in DOM order, resolves those rules, and lays the parts out with
// `FieldRow` (the grid's first row) above the validation errors.
//
// Text entry. ImageRenderer (snapshot tests) cannot draw AppKit-backed controls such as
// TextField / SecureField, and SwiftUI's own Text does not lay out like Chromium. So the
// textbox has two states with one code path (`Textbox`):
//   * resting (not editing): the value, or the placeholder, drawn with CSSText exactly as
//     Chromium draws an unfocused <input>/<textarea> (no caret); this is what snapshots see;
//   * editing: after a click, a tap on the field, or keyboard focus (the resting view is
//     focusable), a plain SwiftUI TextField / SecureField (vertical axis for TextArea) is
//     put over the same frame, focused, and edits the bound value; losing focus returns
//     to the resting state. The placeholder stays drawn with CSSText while editing.
//     Under `axoStaticRendering` (snapshots) the textbox never leaves the resting state.
// Edits go through `limit(old:new:…)`, the port of `useTextField`'s onBeforeInput/onInput:
// an insertion is truncated so the value stays within maxBytes (UTF-8) and maxGraphemes.

import SwiftUI

public enum AxoBaseField {
    /// Visual style of the field.
    public enum Variant: Sendable, Hashable { case text, search, listitem }

    /// Placement of an action button, `.leading` or `.trailing` (default).
    public enum Slot: Sendable, Hashable { case leading, trailing }

    /// The type of input control (upstream `Type`; only text-like types).
    public enum TextboxType: Sendable, Hashable { case email, number, password, search, tel, text, url }

    /// How an `Input` sizes itself horizontally.
    public enum InputSizing: Sendable, Hashable { case fill, fit }

    // MARK: - Parts

    /// One child of a field `Root` (upstream: the Root's React children).
    @MainActor public protocol FieldPart {
        var fieldPart: FieldPartItem { get }
    }

    /// A type-erased field part.
    @MainActor public struct FieldPartItem: FieldPart {
        enum Kind {
            case icon(AxoSymbol.Name)
            case textbox(TextboxConfig)
            case count
            case clear(forceShow: Bool)
            case action(ActionConfig)
            case reveal
            case loading(pending: Bool)
            case error(String)
            case customLeading(AnyView)
            case customTrailing(AnyView)
        }
        let kind: Kind
        public var fieldPart: FieldPartItem { self }

        /// Grid column of row 1 (0 leading, 1 textbox, 2 count, 3 trailing); nil = error row.
        var column: Int? {
            switch kind {
            case .icon, .customLeading: 0
            case .action(let a): a.slot == .leading ? 0 : 3
            case .textbox: 1
            case .count: 2
            case .clear, .loading, .customTrailing, .reveal: 3
            case .error: nil
            }
        }
    }

    @resultBuilder
    @MainActor public enum FieldPartsBuilder {
        public static func buildExpression(_ part: some FieldPart) -> [FieldPartItem] { [part.fieldPart] }
        public static func buildBlock(_ parts: [FieldPartItem]...) -> [FieldPartItem] { parts.flatMap { $0 } }
        public static func buildOptional(_ parts: [FieldPartItem]?) -> [FieldPartItem] { parts ?? [] }
        public static func buildEither(first parts: [FieldPartItem]) -> [FieldPartItem] { parts }
        public static func buildEither(second parts: [FieldPartItem]) -> [FieldPartItem] { parts }
        public static func buildArray(_ parts: [[FieldPartItem]]) -> [FieldPartItem] { parts.flatMap { $0 } }
    }

    struct TextboxConfig {
        var multiline: Bool
        var type: TextboxType
        var placeholder: String
        var sizing: InputSizing = .fill
        var tabularNums = false
        var minLines = 1
        var maxLines = 5
        var autoFocus = false
    }

    enum ActionContent {
        case symbol(AxoSymbol.Name)
        case custom(AnyView)
    }

    struct ActionConfig {
        var slot: Slot
        var label: String
        var disabled: Bool?
        var pressed: Bool?
        var onClick: (@MainActor () -> Void)?
        var content: ActionContent
    }

    // MARK: - VariantOverride / Group context

    struct VariantOverrideKey: EnvironmentKey { static let defaultValue: Variant? = nil }

    struct GroupContext: Sendable, Hashable {
        var disabled: Bool
        var readOnly: Bool
    }

    struct GroupKey: EnvironmentKey { static let defaultValue: GroupContext? = nil }

    /// `<AxoBaseField.VariantOverride>`: forces the variant of the fields and groups inside.
    public struct VariantOverride<Content: View>: View {
        let variant: Variant
        let content: Content
        public init(variant: Variant, @ViewBuilder content: () -> Content) {
            self.variant = variant
            self.content = content()
        }
        public var body: some View { content.environment(\.axoFieldVariantOverride, variant) }
    }

    // MARK: - Group

    /// `<AxoBaseField.Group>`: several Roots (and Separators) in one container (`flex items-start`).
    public struct Group<Content: View>: View {
        let variant: Variant?
        let label: String?
        let disabled: Bool
        let readOnly: Bool
        let content: Content
        @Environment(\.axoFieldVariantOverride) var variantOverride

        public init(variant: Variant? = nil, label: String? = nil, disabled: Bool = false, readOnly: Bool = false,
                    @ViewBuilder content: () -> Content) {
            self.variant = variant
            self.label = label
            self.disabled = disabled
            self.readOnly = readOnly
            self.content = content()
        }

        public var body: some View {
            CSSFlex(.row, align: .start) { content }
                .environment(\.axoFieldGroup, GroupContext(disabled: disabled, readOnly: readOnly))
                .modifier(Container(variant: variantOverride ?? variant ?? .text))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label ?? "")
        }
    }

    /// `<AxoBaseField.Separator>`: a vertical divider between the Roots of a Group.
    public struct Separator: View {
        public init() {}
        public var body: some View {
            // mx-2 my-2 h-[stretch] rounded-xs border-l border-secondary
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 1, bottomLeading: 1))
                .fill(AxoColor.borderSecondary)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(8)
                .flexItem(shrink: 0, alignSelf: .stretch)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Container (variants)

    /// `.axo-field-container` + `-text` / `-search` / `-listitem`.
    struct Container: ViewModifier {
        let variant: Variant
        func body(content: Content) -> some View {
            switch variant {
            case .text:
                // bg-control border-[0.5px] border-primary shadow-elevation-0 shadow-no-outline curved-lg
                // (Chromium lays the 0.5px border out as 1px.)
                content
                    .padding(1)
                    .background { SuperellipseRect.curved(AxoRadius.lg).fill(AxoColor.fillControl) }
                    .overlay { SuperellipseRect.curved(AxoRadius.lg).strokeBorder(AxoColor.borderPrimary, lineWidth: 1) }
                    .axoShadow(.baseShadowElevation0, in: SuperellipseRect.curved(AxoRadius.lg))
            case .search:
                content.background { Capsule().fill(AxoColor.fillPrimary) }
            case .listitem:
                content.contentShape(SuperellipseRect.curved(AxoRadius.xl))
            }
        }
    }

    // MARK: - Root

    struct Context {
        var value: Binding<String>
        var maxGraphemes: Int
        var maxBytes: Int
        var disabled: Bool
        var readOnly: Bool
        var variant: Variant
        var revealed: Binding<Bool>?
        var editing: Binding<Bool>
    }

    /// `<AxoBaseField.Root>`
    public struct Root: View {
        let variant: Variant?
        let value: Binding<String>
        let maxGraphemes: Int
        let maxBytes: Int
        let disabled: Bool
        let readOnly: Bool
        let parts: [FieldPartItem]
        let revealed: Binding<Bool>?
        @Environment(\.axoFieldVariantOverride) var variantOverride
        @Environment(\.axoFieldGroup) var group
        @Environment(\.axoStaticRendering) var staticRendering
        @State private var editing = false

        /// An `autoFocus` input is focused on open; offscreen rendering never runs `onAppear`,
        /// so it shows the focused state from the start.
        var autoFocused: Bool {
            staticRendering && parts.contains { if case .textbox(let c) = $0.kind { c.autoFocus } else { false } }
        }

        public init(variant: Variant? = nil, value: Binding<String>, maxGraphemes: Int, maxBytes: Int, disabled: Bool = false,
                    readOnly: Bool = false, @FieldPartsBuilder parts: () -> [FieldPartItem]) {
            self.init(variant: variant, value: value, maxGraphemes: maxGraphemes, maxBytes: maxBytes, disabled: disabled,
                      readOnly: readOnly, revealed: nil, parts: parts())
        }

        init(variant: Variant?, value: Binding<String>, maxGraphemes: Int, maxBytes: Int, disabled: Bool, readOnly: Bool,
             revealed: Binding<Bool>?, parts: [FieldPartItem]) {
            self.variant = variant
            self.value = value
            self.maxGraphemes = maxGraphemes
            self.maxBytes = maxBytes
            self.disabled = disabled
            self.readOnly = readOnly
            self.revealed = revealed
            self.parts = parts
        }

        public var body: some View {
            let resolvedVariant = variantOverride ?? variant ?? .text
            let ctx = Context(value: value, maxGraphemes: maxGraphemes, maxBytes: maxBytes,
                              disabled: group?.disabled == true || disabled, readOnly: group?.readOnly == true || readOnly,
                              variant: resolvedVariant, revealed: revealed, editing: $editing)
            let rules = Rules(parts, value: value.wrappedValue)
            let row = Array(parts.enumerated()).filter { $0.element.column != nil }
            let errors = Array(parts.enumerated()).filter { $0.element.column == nil }
            VStack(alignment: .leading, spacing: 0) {
                FieldRow(leadingMin: rules.textboxFirst ? 10 : 0, trailingMin: rules.textboxLast ? 10 : 0, fit: rules.fit) {
                    ForEach(row, id: \.offset) { entry in
                        PartView(item: entry.element, ctx: ctx, rules: rules)
                            .layoutValue(key: FieldRow.ColumnKey.self, value: entry.element.column ?? 1)
                    }
                }
                ForEach(errors, id: \.offset) { entry in
                    PartView(item: entry.element, ctx: ctx, rules: rules)
                }
            }
            .frame(maxWidth: rules.fit ? nil : .infinity, alignment: .leading)
            .modifier(RootContainer(variant: resolvedVariant, inGroup: group != nil, fit: rules.fit, focused: editing || autoFocused))
        }
    }

    /// The `:has()` rules of _AxoBaseField.css, resolved from the parts list.
    @MainActor struct Rules {
        var textboxFirst = false
        var textboxLast = false
        var fit = false
        var hasTrailing = false
        var hideIcon = false
        var hideLeadingAction = false
        var hideClear = false
        var hideTrailingAction = false
        var hidePendingLoading = false
        var valueEmpty: Bool

        init(_ parts: [FieldPartItem], value: String) {
            valueEmpty = value.isEmpty
            var customLeading = false, leadingAction = false, trailingAction = false, customTrailing = false, pending = false
            for (i, p) in parts.enumerated() {
                switch p.kind {
                case .textbox(let t):
                    textboxFirst = i == 0
                    textboxLast = i == parts.count - 1
                    fit = !t.multiline && t.sizing == .fit
                case .action(let a):
                    if a.slot == .leading { leadingAction = true } else { trailingAction = true }
                case .reveal: trailingAction = true
                case .customLeading: customLeading = true
                case .customTrailing: customTrailing = true
                case .loading(let isPending): if isPending { pending = true }
                default: break
                }
                if p.column == 3 { hasTrailing = true }
            }
            hideIcon = customLeading || leadingAction
            hideLeadingAction = customLeading
            hideClear = trailingAction || pending || customTrailing
            hideTrailingAction = pending || customTrailing
            hidePendingLoading = customTrailing
        }
    }

    /// Container styling of a Root, or (inside a Group) its flex item sizing.
    struct RootContainer: ViewModifier {
        let variant: Variant
        let inGroup: Bool
        let fit: Bool
        let focused: Bool
        func body(content: Content) -> some View {
            if inGroup {
                // flex-1 grow-[calc(infinity)]; with a fit textbox: grow
                content.flexItem(grow: fit ? 1 : 1_000_000_000, shrink: 1, basis: 0)
            } else {
                content.modifier(Container(variant: variant)).axoFocusRing(focused, in: AxoBaseField.shape(variant))
            }
        }
    }

    /// The container's shape per variant (curved-lg, rounded-full, curved-xl).
    static func shape(_ variant: Variant) -> AnyInsettableShape {
        switch variant {
        case .text: AnyInsettableShape(SuperellipseRect.curved(AxoRadius.lg))
        case .search: AnyInsettableShape(Capsule())
        case .listitem: AnyInsettableShape(SuperellipseRect.curved(AxoRadius.xl))
        }
    }

    // MARK: - Row layout

    /// Row 1 of the field grid. Columns 0, 2 and 3 are as wide as their widest part
    /// (min-content; parts sharing a cell overlap and stretch to it); column 1, the textbox,
    /// takes the rest, or its content width when `fit`. The textbox wrapper's subgrid
    /// padding (`first:ps-2.5`, `last:pe-2.5`) gives columns 0 and 3 their minimum widths.
    struct FieldRow: Layout {
        struct ColumnKey: LayoutValueKey { static let defaultValue = 1 }
        var leadingMin: CGFloat
        var trailingMin: CGFloat
        var fit: Bool

        func widths(_ subviews: Subviews, available: CGFloat?) -> [CGFloat] {
            var w: [CGFloat] = [leadingMin, 0, 0, trailingMin]
            var content: CGFloat = 0
            for s in subviews {
                let c = s[ColumnKey.self]
                let natural = s.sizeThatFits(.unspecified).width
                if c == 1 { content = max(content, natural) } else { w[c] = max(w[c], natural) }
            }
            let fixed = w[0] + w[2] + w[3]
            if fit || available == nil { w[1] = content } else if let available { w[1] = max(0, available - fixed) }
            return w
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = widths(subviews, available: proposal.width)
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w[$0[ColumnKey.self]], height: nil)).height }.max() ?? 0
            return CGSize(width: w.reduce(0, +), height: h)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let w = widths(subviews, available: bounds.width)
            var x: [CGFloat] = [0, 0, 0, 0]
            for i in 1..<4 { x[i] = x[i - 1] + w[i - 1] }
            for s in subviews {
                let c = s[ColumnKey.self]
                s.place(at: CGPoint(x: bounds.minX + x[c], y: bounds.minY), proposal: ProposedViewSize(width: w[c], height: nil))
            }
        }
    }

    // MARK: - Part rendering

    struct PartView: View {
        let item: FieldPartItem
        let ctx: Context
        let rules: Rules

        var body: some View {
            switch item.kind {
            case .icon(let symbol):
                // ps-2.5 pe-1, flex h-[stretch] max-h-8 items-center justify-center, text-secondary
                AxoSymbol.Icon(symbol, size: 16, label: nil)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(height: 32)
                    .cssTextColor(ctx.disabled ? .labelDisabled : .labelSecondary)
                    .hiddenIf(rules.hideIcon)
                    .accessibilityHidden(true)
            case .textbox(let config):
                Textbox(config: config, ctx: ctx)
            case .count:
                CountView(ctx: ctx, hasTrailing: rules.hasTrailing)
            case .clear(let forceShow):
                ClearButton(ctx: ctx).hiddenIf(rules.hideClear || (rules.valueEmpty && !forceShow))
            case .action(let config):
                ActionButton(config: config, ctx: ctx)
                    .hiddenIf(config.slot == .leading ? rules.hideLeadingAction : rules.hideTrailingAction)
            case .reveal:
                let revealed = ctx.revealed?.wrappedValue ?? false
                ActionButton(config: ActionConfig(slot: .trailing, label: "Show Password", disabled: nil, pressed: revealed,
                                                  onClick: { ctx.revealed?.wrappedValue.toggle() },
                                                  content: .symbol(revealed ? "visible-slash" : "visible")), ctx: ctx)
                    .hiddenIf(rules.hideTrailingAction)
            case .loading(let pending):
                LoadingView(pending: pending).hiddenIf(!pending || rules.hidePendingLoading)
            case .error(let message):
                // px-3.5 pb-1.5 type-body-small text-destructive
                CSSText(message, type: .bodySmall, color: .labelDestructive)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            case .customLeading(let content), .customTrailing(let content):
                content.frame(height: 32)
            }
        }
    }

    /// `<AxoBaseField.LoadingIndicator>`: box-content min-w-4 ps-1 pe-1.5, flex items-center.
    struct LoadingView: View {
        let pending: Bool
        var body: some View {
            ZStack {
                // `<AxoLoadingIndicator.Root size="sm">` (regular weight, default variant, no track)
                if pending { AxoBaseSpinner.Root(size: .sm, weight: .regular, variant: .default, value: .indeterminate, track: false) }
            }
            .frame(minWidth: 16, alignment: .leading)
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .accessibilityLabel(pending ? "Loading" : "")
        }
    }

    // MARK: - Count

    static let showRemainingCountThreshold = 0.5
    static let warnRemainingCountThreshold = 0.25

    /// The remaining count shown by `Count` and the maximum it is measured against.
    static func remaining(_ value: String, maxBytes: Int, maxGraphemes: Int) -> (remaining: Int, max: Int) {
        if value.isEmpty { return (maxGraphemes, maxGraphemes) }
        let remainingBytes = maxBytes - value.utf8.count
        let remainingChars = maxGraphemes - value.count
        return remainingBytes > remainingChars ? (remainingChars, maxGraphemes) : (remainingBytes, maxBytes)
    }

    struct CountView: View {
        let ctx: Context
        let hasTrailing: Bool
        /// `min-w-[2ch]` at 12px Inter: the "0" advance is 0.625em.
        static let minWidth: CGFloat = 2 * 0.625 * 12

        var body: some View {
            let (remaining, max) = AxoBaseField.remaining(ctx.value.wrappedValue, maxBytes: ctx.maxBytes, maxGraphemes: ctx.maxGraphemes)
            let show = Double(remaining) <= Double(max) * AxoBaseField.showRemainingCountThreshold
            let warn = Double(remaining) <= Double(max) * AxoBaseField.warnRemainingCountThreshold
            let inactive = ctx.disabled || ctx.readOnly
            let color: AxoColor = warn ? (inactive ? .labelDestructiveDisabled : .labelDestructive) : (inactive ? .labelDisabled : .labelSecondary)
            // flex h-[stretch] max-h-8 items-center justify-end, box-content min-w-[2ch] px-1 (pe-2.5 without trailing parts)
            CSSText(String(remaining), style: CSSTextStyle(.bodySmall).tabularNums(), wrap: .nowrap, color: color)
                .frame(minWidth: Self.minWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, hasTrailing ? 4 : 10)
                .frame(height: 32)
                .hiddenIf(!show)
        }
    }

    // MARK: - Buttons (Clear, Action)

    struct PlainButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }

    /// Hover background of `.axo-field-action-inner` / `.axo-field-clear-inner` per variant.
    static func hoverFill(_ variant: Variant) -> AxoColor {
        variant == .search ? .fillPrimary : .surfaceSecondary
    }

    /// `<AxoBaseField.Clear>`: py-1.5 ps-0.5 pe-1.5 around a p-0.5 rounded-full inner box.
    struct ClearButton: View {
        let ctx: Context
        @State private var hovered = false

        var body: some View {
            let disabled = ctx.disabled || ctx.readOnly
            let hover = hovered && !disabled
            Button {
                guard !disabled else { return }
                ctx.value.wrappedValue = ""
                ctx.editing.wrappedValue = true
            } label: {
                AxoSymbol.Icon("x", size: 16, label: nil)
                    .padding(2)
                    .frame(maxWidth: .infinity)
                    .background { if hover { Capsule().fill(AxoBaseField.hoverFill(ctx.variant)) } }
                    .cssTextColor(disabled ? .labelDisabled : (hover ? .labelPrimary : .labelSecondary))
                    .padding(.leading, 2)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(disabled)
            .onHover { hovered = $0 }
            .accessibilityLabel("Clear")
        }
    }

    /// `<AxoBaseField.Action>` / `CustomAction`: px-1 py-0.75 around a p-1 rounded-full inner box.
    struct ActionButton: View {
        let config: ActionConfig
        let ctx: Context
        @State private var hovered = false

        var body: some View {
            let disabled = config.disabled ?? ctx.disabled
            let hover = hovered && !disabled
            Button {
                guard !disabled else { return }
                config.onClick?()
            } label: {
                SwiftUI.Group {
                    switch config.content {
                    case .symbol(let name): AxoSymbol.Icon(name, size: 18, label: nil)
                    case .custom(let view): view
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity)
                .background { if hover { Capsule().fill(AxoBaseField.hoverFill(ctx.variant)) } }
                .cssTextColor(disabled ? .labelDisabled : (hover ? .labelPrimary : .labelSecondary))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovered = $0 }
            .accessibilityLabel(config.label)
            .accessibilityAddTraits(config.pressed == true ? .isSelected : [])
            .accessibilityHint(disabled ? "Disabled" : "")
        }
    }

    // MARK: - Textbox

    /// `<input>` / `<textarea>` of the field (see the file comment for resting vs editing).
    struct Textbox: View {
        let config: TextboxConfig
        let ctx: Context
        @FocusState private var liveFocused: Bool
        @FocusState private var restingFocused: Bool
        @Environment(\.axoStaticRendering) var isStatic

        static let type = AxoType.bodyLarge

        var interactive: Bool { !ctx.disabled && !ctx.readOnly && !isStatic }
        var editing: Bool { ctx.editing.wrappedValue && interactive }
        var concealed: Bool { config.type == .password && ctx.revealed?.wrappedValue != true }

        /// What an unfocused control shows: the value (bullets for a password), or nothing.
        var displayed: String {
            let value = ctx.value.wrappedValue
            return concealed ? String(repeating: "\u{2022}", count: value.count) : value
        }

        var body: some View {
            let value = ctx.value.wrappedValue
            let lineHeight = Self.type.lineHeight
            let showPlaceholder = value.isEmpty
            ZStack(alignment: .topLeading) {
                // Resting appearance (also the placeholder while editing an empty value).
                CSSText(showPlaceholder ? config.placeholder : displayed,
                        style: config.tabularNums ? CSSTextStyle(Self.type).tabularNums() : CSSTextStyle(Self.type),
                        wrap: config.multiline ? .wrap : .nowrap,
                        color: showPlaceholder ? .labelPlaceholder : (ctx.disabled ? .labelDisabled : .labelPrimary))
                    .opacity(editing && !showPlaceholder ? 0 : 1)
                if editing { live }
            }
            // py-1.5; text starts 4px into the textbox column (input: indent-1, textarea: ps-26 − mx-25)
            .frame(maxWidth: config.sizing == .fit && !config.multiline ? nil : .infinity, alignment: .topLeading)
            .frame(minHeight: CGFloat(config.multiline ? config.minLines : 1) * lineHeight,
                   maxHeight: CGFloat(config.multiline ? config.maxLines : 1) * lineHeight, alignment: .topLeading)
            .padding(.leading, 4)
            .padding(.vertical, 6)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { begin() }
            .focusable(interactive && !editing)
            .focused($restingFocused)
            .focusEffectDisabled()
            .onChange(of: restingFocused) { _, focused in if focused { begin() } }
            .onAppear { if config.autoFocus { begin() } }
            .accessibilityElement()
            .accessibilityLabel(config.placeholder)
            .accessibilityValue(concealed ? "" : value)
            .accessibilityAddTraits(config.type == .search ? .isSearchField : [])
            .accessibilityAction { begin() }
        }

        func begin() {
            guard interactive else { return }
            ctx.editing.wrappedValue = true
        }

        var limited: Binding<String> {
            let value = ctx.value
            let maxBytes = ctx.maxBytes, maxGraphemes = ctx.maxGraphemes
            return Binding(get: { value.wrappedValue }, set: { new in
                value.wrappedValue = AxoBaseField.limit(old: value.wrappedValue, new: new, maxBytes: maxBytes, maxGraphemes: maxGraphemes)
            })
        }

        @ViewBuilder var live: some View {
            SwiftUI.Group {
                if concealed {
                    SecureField("", text: limited)
                } else if config.multiline {
                    TextField("", text: limited, axis: .vertical).lineLimit(config.minLines...config.maxLines)
                } else {
                    TextField("", text: limited)
                }
            }
            .textFieldStyle(.plain)
            .font(Self.type.font)
            .tracking(Self.type.tracking * Self.type.size)
            .foregroundStyle(AxoColor.labelPrimary)
            .autocorrectionDisabled(config.type == .password)
            .focused($liveFocused)
            .onAppear { liveFocused = true }
            .onChange(of: liveFocused) { _, focused in if !focused { ctx.editing.wrappedValue = false } }
            .onExitCommand { ctx.editing.wrappedValue = false }
        }
    }

    // MARK: - Length limits (useTextField onBeforeInput / onInput, utf8.std.ts)

    /// Truncates `string` to at most `maxBytes` UTF-8 bytes and `maxGraphemes` grapheme clusters.
    public static func truncate(_ string: String, maxBytes: Int, maxGraphemes: Int) -> String {
        var bytes = 0, count = 0
        var out = ""
        for c in string {
            let b = c.utf8.count
            if count + 1 > maxGraphemes || bytes + b > maxBytes { break }
            bytes += b
            count += 1
            out.append(c)
        }
        return out
    }

    /// The value after an edit from `old` to `new`: an insertion that would exceed the
    /// limits keeps only as much of the inserted text as fits (prefix and suffix kept).
    public static func limit(old: String, new: String, maxBytes: Int, maxGraphemes: Int) -> String {
        if new.utf8.count <= maxBytes && new.count <= maxGraphemes { return new }
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let prefix = String(n[0..<p]), suffix = String(n[(n.count - s)...]), inserted = String(n[p..<(n.count - s)])
        let base = prefix + suffix
        let fitted = truncate(inserted, maxBytes: maxBytes - base.utf8.count, maxGraphemes: maxGraphemes - base.count)
        return truncate(prefix + fitted + suffix, maxBytes: maxBytes, maxGraphemes: maxGraphemes)
    }

    // MARK: - Public parts

    /// `<AxoBaseField.Icon>`
    public struct Icon: FieldPart {
        let symbol: AxoSymbol.Name
        public init(symbol: AxoSymbol.Name) { self.symbol = symbol }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .icon(symbol)) }
    }

    /// `<AxoBaseField.Input>`
    public struct Input: FieldPart {
        var config: TextboxConfig
        public init(placeholder: String, sizing: InputSizing = .fill, tabularNums: Bool = false, required: Bool = false,
                    autoFocus: Bool = false) {
            config = TextboxConfig(multiline: false, type: .text, placeholder: placeholder, sizing: sizing, tabularNums: tabularNums,
                                   autoFocus: autoFocus)
        }
        init(type: TextboxType, placeholder: String, autoFocus: Bool = false) {
            config = TextboxConfig(multiline: false, type: type, placeholder: placeholder, autoFocus: autoFocus)
        }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .textbox(config)) }
    }

    /// `<AxoBaseField.TextArea>`: grows with its content from `minLines` to `maxLines`.
    public struct TextArea: FieldPart {
        var config: TextboxConfig
        public init(placeholder: String, minLines: Int = 1, maxLines: Int = 5, tabularNums: Bool = false, required: Bool = false,
                    autoFocus: Bool = false) {
            precondition(minLines <= maxLines, "minLines (\(minLines)) must be <= than maxLines (\(maxLines))")
            config = TextboxConfig(multiline: true, type: .text, placeholder: placeholder, tabularNums: tabularNums, minLines: minLines,
                                   maxLines: maxLines, autoFocus: autoFocus)
        }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .textbox(config)) }
    }

    /// `<AxoBaseField.Count>`: remaining graphemes/bytes, shown from half the limit, red from a quarter.
    public struct Count: FieldPart {
        public init() {}
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .count) }
    }

    /// `<AxoBaseField.Clear>`: clears the value; hidden while empty unless `forceShow`.
    public struct Clear: FieldPart {
        let forceShow: Bool
        public init(forceShow: Bool = false) { self.forceShow = forceShow }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .clear(forceShow: forceShow)) }
    }

    /// `<AxoBaseField.Action>`: an icon button in the leading or trailing slot.
    public struct Action: FieldPart {
        let config: ActionConfig
        public init(slot: Slot = .trailing, label: String, symbol: AxoSymbol.Name, disabled: Bool? = nil, pressed: Bool? = nil,
                    onClick: (@MainActor () -> Void)? = nil) {
            config = ActionConfig(slot: slot, label: label, disabled: disabled, pressed: pressed, onClick: onClick, content: .symbol(symbol))
        }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .action(config)) }
    }

    /// `<AxoBaseField.CustomAction>`: an action button with custom content.
    public struct CustomAction<Content: View>: FieldPart {
        let config: ActionConfig
        public init(slot: Slot = .trailing, label: String, disabled: Bool? = nil, pressed: Bool? = nil,
                    onClick: (@MainActor () -> Void)? = nil, @ViewBuilder content: () -> Content) {
            config = ActionConfig(slot: slot, label: label, disabled: disabled, pressed: pressed, onClick: onClick,
                                  content: .custom(AnyView(content())))
        }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .action(config)) }
    }

    /// `<AxoBaseField.LoadingIndicator>`: a spinner in the trailing slot while `pending`.
    public struct LoadingIndicator: FieldPart {
        let pending: Bool
        public init(pending: Bool) { self.pending = pending }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .loading(pending: pending)) }
    }

    /// `<AxoBaseField.ValidationError>`: a message below the textbox.
    public struct ValidationError: FieldPart {
        let message: String
        public init(_ message: String) { self.message = message }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .error(message)) }
    }

    /// `<AxoBaseField.CustomLeadingSlot>`: hides the icon and leading actions.
    public struct CustomLeadingSlot<Content: View>: FieldPart {
        let content: AnyView
        public init(@ViewBuilder content: () -> Content) { self.content = AnyView(content()) }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .customLeading(content)) }
    }

    /// `<AxoBaseField.CustomTrailingSlot>`: hides Clear, trailing actions and the loading indicator.
    public struct CustomTrailingSlot<Content: View>: FieldPart {
        let content: AnyView
        public init(@ViewBuilder content: () -> Content) { self.content = AnyView(content()) }
        public var fieldPart: FieldPartItem { FieldPartItem(kind: .customTrailing(content)) }
    }

    /// The internal Reveal part of AxoPasswordField.
    struct Reveal: FieldPart {
        var fieldPart: FieldPartItem { FieldPartItem(kind: .reveal) }
    }
}

extension EnvironmentValues {
    var axoFieldVariantOverride: AxoBaseField.Variant? {
        get { self[AxoBaseField.VariantOverrideKey.self] }
        set { self[AxoBaseField.VariantOverrideKey.self] = newValue }
    }
    var axoFieldGroup: AxoBaseField.GroupContext? {
        get { self[AxoBaseField.GroupKey.self] }
        set { self[AxoBaseField.GroupKey.self] = newValue }
    }
}

extension View {
    /// CSS `visibility: hidden` when `hidden` (keeps the layout box).
    @ViewBuilder func hiddenIf(_ hidden: Bool) -> some View {
        if hidden { self.hidden() } else { self }
    }
}
