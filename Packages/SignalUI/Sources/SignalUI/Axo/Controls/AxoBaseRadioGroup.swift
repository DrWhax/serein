// Port of ts/axo/controls/_AxoBaseRadioGroup.dom.tsx (Radix RadioGroup parts shared by
// AxoRadioGroup and the radio list items): the selection context, the round Indicator,
// Label and Description.

import SwiftUI

public enum AxoBaseRadioGroup {
    /// What `RadioGroup.Root` provides to its items.
    struct Context {
        var value: String?
        var disabled: Bool
        var select: @MainActor (String) -> Void
    }

    struct ContextKey: EnvironmentKey { static let defaultValue: Context? = nil }

    /// State of one item (Radix `data-state`, `data-disabled`) for its parts.
    struct ItemState: Sendable, Hashable {
        var checked: Bool
        var disabled: Bool
    }

    struct ItemStateKey: EnvironmentKey { static let defaultValue = ItemState(checked: false, disabled: false) }

    /// `<AxoBaseRadioGroup.Item>`: a selectable option; `content` lays out the Indicator and Label.
    public struct Item<Content: View>: View {
        let value: String
        let disabled: Bool
        let content: Content
        @Environment(\.axoRadioGroup) var group

        public init(value: String, disabled: Bool = false, @ViewBuilder content: () -> Content) {
            self.value = value
            self.disabled = disabled
            self.content = content()
        }

        public var body: some View {
            let isDisabled = disabled || group?.disabled == true
            let checked = group?.value == value
            Button {
                guard !isDisabled else { return }
                group?.select(value)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(PressedStateStyle(state: ItemState(checked: checked, disabled: isDisabled)))
            .disabled(isDisabled)
            .accessibilityAddTraits(checked ? [.isSelected] : [])
        }
    }

    /// Passes the pressed state (`:active`) to the parts with the item state.
    struct PressedStateStyle: ButtonStyle {
        let state: ItemState
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .environment(\.axoRadioItemState, state)
                .environment(\.axoRadioItemPressed, configuration.isPressed && !state.disabled)
        }
    }

    struct PressedKey: EnvironmentKey { static let defaultValue = false }

    /// `<AxoBaseRadioGroup.Indicator>`: size-5 circle (border-primary, inset-shadow-on-color),
    /// accent-filled with a 9px on-colour dot when checked.
    public struct Indicator: View {
        @Environment(\.axoRadioItemState) var state
        @Environment(\.axoRadioItemPressed) var pressed
        public init() {}

        static let insetShadow: [AxoShadowLayer] = [.init(inset: true, x: 0, y: 0.5, blur: 1, spread: 0, color: RGBA(0, 0, 0, 0.12))]

        public var body: some View {
            let fill: AxoColor = state.checked ? (pressed ? .fillAccentPressed : .fillAccent) : (pressed ? .fillControlPressed : .fillControl)
            ZStack {
                if state.checked {
                    Circle()
                        .fill(state.disabled ? AxoColor.labelDisabledOncolor : AxoColor.labelPrimaryOncolor)
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: 20, height: 20)
            .background { Circle().fill(fill) }
            .cssBoxShadow(state.disabled ? [] : Self.insetShadow, in: Circle())
            .overlay { Circle().strokeBorder(state.disabled ? AxoColor.borderSecondary : AxoColor.borderPrimary, lineWidth: 1) }
            .flexItem(shrink: 0)
            .accessibilityHidden(true)
        }
    }

    /// `<AxoBaseRadioGroup.Label>`: the item's label text (styled by the caller).
    public struct Label<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { content }
    }

    /// `<AxoBaseRadioGroup.Description>`: secondary text describing the item.
    public struct Description<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { content }
    }
}

extension EnvironmentValues {
    var axoRadioGroup: AxoBaseRadioGroup.Context? {
        get { self[AxoBaseRadioGroup.ContextKey.self] }
        set { self[AxoBaseRadioGroup.ContextKey.self] = newValue }
    }
    var axoRadioItemState: AxoBaseRadioGroup.ItemState {
        get { self[AxoBaseRadioGroup.ItemStateKey.self] }
        set { self[AxoBaseRadioGroup.ItemStateKey.self] = newValue }
    }
    var axoRadioItemPressed: Bool {
        get { self[AxoBaseRadioGroup.PressedKey.self] }
        set { self[AxoBaseRadioGroup.PressedKey.self] = newValue }
    }
}
