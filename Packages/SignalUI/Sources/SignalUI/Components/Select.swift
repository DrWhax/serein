// Port of ts/components/Select.dom.tsx (+ stylesheets/components/Select.scss): the legacy
// native dropdown. A 40px box (1px gray-25 border, 4px corners; gray-90 on gray-60 in dark),
// body-2 text 12px in, the 16px dropdown chevron 8px from the end; a 3px ultramarine border
// when focused by keyboard. The options open as a native menu (disabled ones greyed).

import SwiftUI

public struct Select: View {
    public struct Option: Sendable, Hashable {
        public var text: String
        public var value: String
        public var disabled = false
        public init(text: String, value: String, disabled: Bool = false) {
            self.text = text
            self.value = value
            self.disabled = disabled
        }
    }

    let options: [Option]
    let value: String?
    let disabled: Bool
    let ariaLabel: String?
    let onChange: (String) -> Void
    @FocusState private var focused: Bool

    public init(options: [Option], value: String?, disabled: Bool = false, ariaLabel: String? = nil, onChange: @escaping (String) -> Void) {
        self.options = options
        self.value = value
        self.disabled = disabled
        self.ariaLabel = ariaLabel
        self.onChange = onChange
    }

    /// A native select shows its first option when the value matches none.
    var shown: Option? { options.first { $0.value == value } ?? options.first }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Menu {
            ForEach(options, id: \.value) { o in
                SwiftUI.Button(o.text) { onChange(o.value) }.disabled(o.disabled)
            }
        } label: {
            CSSText(shown?.text ?? "", style: LegacyType.body2(), wrap: .truncate,
                    color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
                .padding(.leading, 12)
                .padding(.trailing, 32)
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
                .background(shape.fill(AxoColor(light: RGBA(0, 0, 0, 0), dark: LegacyColor.gray90)))
                .overlay(shape.strokeBorder(focused ? AxoColor(LegacyColor.ultramarine) : AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60),
                                            lineWidth: focused ? 3 : 1))
                .overlay(alignment: .topTrailing) {
                    SignalIcon("v3/dropdown/dropdown-compact-light", size: 16, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray15), mask: true)
                        .padding(.top, 11)
                        .padding(.trailing, 8)
                }
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(disabled)
        .frame(minWidth: 124)
        .focused($focused)
        .accessibilityLabel(ariaLabel ?? "")
    }
}
