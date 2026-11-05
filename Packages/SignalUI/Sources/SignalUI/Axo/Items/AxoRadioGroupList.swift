// Port of ts/axo/items/AxoRadioGroupList.dom.tsx: a list whose items are radio options
// (each item is the radio button, with the indicator leading).

import SwiftUI

public enum AxoRadioGroupList {
    /// `<AxoRadioGroupList.Root>`
    public struct Root<Content: View>: View {
        let title: String?
        let description: String?
        let help: String?
        let disabled: Bool
        @Binding var value: String
        let content: Content

        public init(title: String? = nil, description: String? = nil, help: String? = nil, value: Binding<String>, disabled: Bool = false,
                    @ViewBuilder content: () -> Content) {
            self.title = title
            self.description = description
            self.help = help
            self.disabled = disabled
            _value = value
            self.content = content()
        }

        public var body: some View {
            let binding = $value
            AxoList.Root {
                if let title {
                    AxoList.Header {
                        AxoList.Label(title)
                        // We probably don't ever want to show a description without a title
                        if let description { AxoList.Description(description) }
                    }
                }
                AxoList.Body {
                    AxoBaseItem.Group(spacing: .md) { content }
                        .environment(\.axoRadioGroup, AxoBaseRadioGroup.Context(value: value, disabled: disabled,
                                                                                 select: { binding.wrappedValue = $0 }))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(title ?? "")
                }
                if let help {
                    AxoList.Footer { AxoList.FooterDescription(help) }
                }
            }
        }
    }

    /// `<AxoRadioGroupList.Item>`: the item is the radio (`AxoBaseRadioGroup.Item` as a
    /// `<button>` `AxoBaseItem.Root`), with the indicator leading.
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
            let select = group?.select
            let value = value
            AxoBaseItem.Root(disabled: isDisabled, action: { select?(value) }) {
                AxoBaseItem.Leading { AxoBaseRadioGroup.Indicator() }
                AxoBaseItem.Content { content }
            }
            .environment(\.axoRadioItemState, AxoBaseRadioGroup.ItemState(checked: checked, disabled: isDisabled))
            .accessibilityAddTraits(checked ? [.isSelected] : [])
        }
    }

    /// `<AxoRadioGroupList.Label>`
    public struct Label: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View { AxoBaseItem.Label(text) }
    }

    /// `<AxoRadioGroupList.Description>`
    public struct Description: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View { AxoBaseItem.Description(text) }
    }
}
