// Port of ts/axo/controls/AxoRadioGroup.dom.tsx: a column of radio buttons, at most one checked.
//
//   AxoRadioGroup.Root(value: $notify) {
//       AxoRadioGroup.Item(value: "all") { AxoRadioGroup.Label("All messages") }
//       AxoRadioGroup.Item(value: "off") { AxoRadioGroup.Label("Off") }
//   }

import SwiftUI

public enum AxoRadioGroup {
    /// `<AxoRadioGroup.Root>`: flex flex-col.
    public struct Root<Content: View>: View {
        let label: String?
        @Binding var value: String?
        let disabled: Bool
        let content: Content

        public init(label: String? = nil, value: Binding<String?>, disabled: Bool = false, @ViewBuilder content: () -> Content) {
            self.label = label
            _value = value
            self.disabled = disabled
            self.content = content()
        }

        public var body: some View {
            let binding = $value
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.axoRadioGroup, AxoBaseRadioGroup.Context(value: value, disabled: disabled, select: { binding.wrappedValue = $0 }))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label ?? "")
        }
    }

    /// `<AxoRadioGroup.Item>`: flex gap-3 py-2.5 text-start — the Indicator, then the label.
    public struct Item<Content: View>: View {
        let value: String
        let disabled: Bool
        let content: Content

        public init(value: String, disabled: Bool = false, @ViewBuilder content: () -> Content) {
            self.value = value
            self.disabled = disabled
            self.content = content()
        }

        public var body: some View {
            AxoBaseRadioGroup.Item(value: value, disabled: disabled) {
                CSSFlex(.row, gap: 12) {
                    AxoBaseRadioGroup.Indicator()
                    content
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `<AxoRadioGroup.Label>`: truncate type-body-large text-primary (text-disabled when disabled).
    public struct Label: View {
        let text: String
        @Environment(\.axoRadioItemState) var state
        public init(_ text: String) { self.text = text }
        public var body: some View {
            AxoBaseRadioGroup.Label {
                CSSText(text, type: .bodyLarge, wrap: .truncate, color: state.disabled ? .labelDisabled : .labelPrimary)
            }
            .flexItem(shrink: 1, minMain: 0)
        }
    }
}
