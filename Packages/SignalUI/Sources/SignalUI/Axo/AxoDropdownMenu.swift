// Port of ts/axo/AxoDropdownMenu.dom.tsx (Radix DropdownMenu): a menu that opens
// below its trigger (sideOffset 4, collision padding 6) in the window's layer host.

import SwiftUI

public enum AxoDropdownMenu {
    /// `<AxoDropdownMenu.Root>` + Trigger + Content.
    public struct Root<Trigger: View, Items: View>: View {
        @Binding var isOpen: Bool
        let placement: AxoPopper.Placement
        let trigger: Trigger
        let items: Items
        @State private var id = UUID().uuidString

        public init(isOpen: Binding<Bool>, side: AxoPopper.Side = .bottom, align: AxoPopper.Align = .center,
                    @ViewBuilder trigger: () -> Trigger, @ViewBuilder items: () -> Items) {
            _isOpen = isOpen
            placement = AxoPopper.Placement(side: side, align: align, sideOffset: 4, collisionPadding: 6)
            self.trigger = trigger()
            self.items = items()
        }

        public var body: some View {
            trigger
                .simultaneousGesture(TapGesture().onEnded { isOpen.toggle() })
                .axoPopper(id: id, isPresented: isOpen, placement: placement, dismiss: { isOpen = false }) {
                    AxoBaseMenu.Content { items }.environment(\.axoMenuClose, AxoMenuAction(run: { isOpen = false }))
                }
        }
    }

    /// Row with hover highlight (`data-highlighted`).
    struct Highlightable<Content: View>: View {
        let disabled: Bool
        let content: (Bool) -> Content
        @State private var hovered = false
        var body: some View {
            content(hovered && !disabled).onHover { hovered = $0 }
        }
    }

    /// `<AxoDropdownMenu.Item>`
    public struct Item: View {
        let text: String
        let symbol: AxoSymbol.Name?
        let description: String?
        let keyboardShortcut: String?
        let disabled: Bool
        let action: () -> Void
        var runs: [CSSTextRun]?
        @Environment(\.axoMenuClose) var close

        /// The label as styled runs (e.g. a bold prefix); `text` stays the accessible name.
        public func runs(_ runs: [CSSTextRun]) -> Self { var c = self; c.runs = runs; return c }

        public init(_ text: String, symbol: AxoSymbol.Name? = nil, description: String? = nil, keyboardShortcut: String? = nil,
                    disabled: Bool = false, action: @escaping () -> Void) {
            self.text = text
            self.symbol = symbol
            self.description = description
            self.keyboardShortcut = keyboardShortcut
            self.disabled = disabled
            self.action = action
        }

        public var body: some View {
            Highlightable(disabled: disabled) { highlighted in
                AxoBaseMenu.Row(leading: .init(symbol: symbol != nil), disabled: disabled, highlighted: highlighted) {
                    if let symbol { AxoBaseMenu.symbol(symbol) }
                } main: {
                    if let description {
                        // ItemTextWithDescription: flex min-w-0 flex-auto flex-col
                        VStack(alignment: .leading, spacing: 0) {
                            CSSText(text, type: .bodyMedium, wrap: .truncate)
                            CSSText(description, type: .bodySmall, color: .labelSecondary)
                        }
                        .flexItem(grow: 1, minMain: 0)
                    } else {
                        AxoBaseMenu.itemText(text, runs: runs)
                    }
                    if let keyboardShortcut { AxoBaseMenu.keyboardShortcut(keyboardShortcut) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { action(); close() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .axoMenuLeading(.init(symbol: symbol != nil))
        }
    }

    /// `<AxoDropdownMenu.CustomItem>`: an item with a custom leading node (`leadingWidth` wide).
    /// `keepsOpen`: the select handler calls `preventDefault()` (the menu stays open).
    public struct CustomItem<LeadingNode: View>: View {
        let text: String
        let leadingWidth: CGFloat
        let disabled: Bool
        let keepsOpen: Bool
        let leadingNode: LeadingNode
        let action: () -> Void
        @Environment(\.axoMenuClose) var close

        public init(_ text: String, leadingWidth: CGFloat, disabled: Bool = false, keepsOpen: Bool = false, action: @escaping () -> Void,
                    @ViewBuilder leading: () -> LeadingNode) {
            self.text = text
            self.leadingWidth = leadingWidth
            self.disabled = disabled
            self.keepsOpen = keepsOpen
            self.action = action
            self.leadingNode = leading()
        }

        public var body: some View {
            Highlightable(disabled: disabled) { highlighted in
                AxoBaseMenu.Row(leading: .init(custom: leadingWidth), disabled: disabled, highlighted: highlighted) {
                    leadingNode
                } main: {
                    AxoBaseMenu.itemText(text)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !disabled else { return }
                action()
                if !keepsOpen { close() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .axoMenuLeading(.init(custom: leadingWidth))
        }
    }

    /// `<AxoDropdownMenu.CheckboxItem>`
    public struct CheckboxItem: View {
        let text: String
        let symbol: AxoSymbol.Name?
        let keyboardShortcut: String?
        let disabled: Bool
        @Binding var checked: Bool
        var runs: [CSSTextRun]?

        /// The label as styled runs (e.g. a bold prefix); `text` stays the accessible name.
        public func runs(_ runs: [CSSTextRun]) -> Self { var c = self; c.runs = runs; return c }

        public init(_ text: String, symbol: AxoSymbol.Name? = nil, keyboardShortcut: String? = nil, disabled: Bool = false, checked: Binding<Bool>) {
            self.text = text
            self.symbol = symbol
            self.keyboardShortcut = keyboardShortcut
            self.disabled = disabled
            _checked = checked
        }

        public var body: some View {
            Highlightable(disabled: disabled) { highlighted in
                AxoBaseMenu.Row(leading: .init(checkPlaceholder: true), disabled: disabled, highlighted: highlighted) {
                    AxoBaseMenu.checkPlaceholder(checked)
                } main: {
                    if let symbol { AxoBaseMenu.symbol(symbol).padding(.trailing, 8) }
                    AxoBaseMenu.itemText(text, runs: runs)
                    if let keyboardShortcut { AxoBaseMenu.keyboardShortcut(keyboardShortcut) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { checked.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(checked ? [.isToggle, .isSelected] : .isToggle)
            .axoMenuLeading(.init(checkPlaceholder: true))
        }
    }

    /// `<AxoDropdownMenu.RadioGroup>`: transparent group providing the selected value.
    public struct RadioGroup<Items: View>: View {
        @Binding var value: String?
        let items: Items
        public init(value: Binding<String?>, @ViewBuilder items: () -> Items) {
            _value = value
            self.items = items()
        }
        public var body: some View {
            Group { items }.environment(\.axoMenuRadio, AxoMenuRadio(value: value, select: { value = $0 }))
        }
    }

    /// `<AxoDropdownMenu.RadioItem>`
    public struct RadioItem: View {
        let text: String
        let value: String
        let symbol: AxoSymbol.Name?
        let keyboardShortcut: String?
        let disabled: Bool
        var runs: [CSSTextRun]?
        @Environment(\.axoMenuRadio) var radio

        /// The label as styled runs (e.g. a bold prefix); `text` stays the accessible name.
        public func runs(_ runs: [CSSTextRun]) -> Self { var c = self; c.runs = runs; return c }

        public init(_ text: String, value: String, symbol: AxoSymbol.Name? = nil, keyboardShortcut: String? = nil, disabled: Bool = false) {
            self.text = text
            self.value = value
            self.symbol = symbol
            self.keyboardShortcut = keyboardShortcut
            self.disabled = disabled
        }

        public var body: some View {
            let selected = radio.value == value
            Highlightable(disabled: disabled) { highlighted in
                AxoBaseMenu.Row(leading: .init(checkPlaceholder: true), disabled: disabled, highlighted: highlighted) {
                    AxoBaseMenu.checkPlaceholder(selected)
                } main: {
                    if let symbol { AxoBaseMenu.symbol(symbol).padding(.trailing, 8) }
                    AxoBaseMenu.itemText(text, runs: runs)
                    if let keyboardShortcut { AxoBaseMenu.keyboardShortcut(keyboardShortcut) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !disabled { radio.select(value) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .axoMenuLeading(.init(checkPlaceholder: true))
        }
    }

    /// `<AxoDropdownMenu.SubTrigger>` (its submenu opens to the side on hover).
    public struct SubTrigger: View {
        let text: String
        let symbol: AxoSymbol.Name?
        let disabled: Bool
        public init(_ text: String, symbol: AxoSymbol.Name? = nil, disabled: Bool = false) {
            self.text = text
            self.symbol = symbol
            self.disabled = disabled
        }
        public var body: some View {
            Highlightable(disabled: disabled) { highlighted in
                AxoBaseMenu.Row(leading: .init(symbol: symbol != nil), disabled: disabled, highlighted: highlighted) {
                    if let symbol { AxoBaseMenu.symbol(symbol) }
                } main: {
                    AxoBaseMenu.itemText(text)
                    AxoSymbol.Icon("chevron-[end]", size: 14, label: nil).flexItem(shrink: 0, autoMarginStart: true)
                }
            }
            .axoMenuLeading(.init(symbol: symbol != nil))
        }
    }

    /// `<AxoDropdownMenu.Sub>` + `<SubContent>`: the SubTrigger opens its items beside the
    /// menu on hover (Radix: side right, align start, alignOffset −6, collision padding 6),
    /// and stays open while the pointer is over either.
    public struct Sub<Items: View>: View {
        let trigger: SubTrigger
        let items: Items
        @State private var overTrigger = false
        @State private var overContent = false
        @State private var id = UUID().uuidString
        @Environment(\.axoMenuClose) var close

        public init(_ trigger: SubTrigger, @ViewBuilder items: () -> Items) {
            self.trigger = trigger
            self.items = items()
        }

        public var body: some View {
            trigger
                .onHover { overTrigger = $0 }
                .onTapGesture { overTrigger = true }
                .axoPopper(id: id, isPresented: !trigger.disabled && (overTrigger || overContent),
                           placement: AxoPopper.Placement(side: .right, align: .start, alignOffset: -6, collisionPadding: 6)) {
                    AxoBaseMenu.Content { items }
                        .environment(\.axoMenuClose, close)
                        .onHover { overContent = $0 }
                }
        }
    }

    public typealias Label = AxoBaseMenu.Label
    public typealias Separator = AxoBaseMenu.Separator
    public typealias ContentSeparator = AxoBaseMenu.ContentSeparator
    public typealias Header = AxoBaseMenu.Header
}

/// Closes the open menu (Radix closes on item select).
public struct AxoMenuAction: Sendable {
    var run: @Sendable @MainActor () -> Void = {}
    @MainActor func callAsFunction() { run() }
}

public struct AxoMenuRadio: Sendable {
    var value: String?
    var select: @Sendable @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var axoMenuRadio = AxoMenuRadio(value: nil)
    @Entry var axoMenuClose = AxoMenuAction()
}
