// Port of ts/axo/items/AxoSwitchItem.dom.tsx: an item whose trailing control is a switch.

import SwiftUI

public enum AxoSwitchItem {
    /// `<AxoSwitchItem.Root>`
    public struct Root: View {
        let symbol: AxoSymbol.Name?
        let label: String
        let description: String?
        let disabled: Bool
        let tooltip: String?
        /// The description as a button (GroupLinkManagement: the link copies itself).
        let onClickDescription: (() -> Void)?
        let descriptionLabel: String?
        @Binding var checked: Bool
        /// Content after the label text (the Privacy page's sealed-sender icon).
        var labelSuffix: AnyView?
        /// The description as styled runs (a link); `onDescriptionAction` gets a run's action.
        var descriptionRuns: [CSSTextRun]?
        var onDescriptionAction: ((String) -> Void)?

        public init(symbol: AxoSymbol.Name? = nil, label: String, description: String? = nil, disabled: Bool = false,
                    checked: Binding<Bool>, tooltip: String? = nil, onClickDescription: (() -> Void)? = nil, descriptionLabel: String? = nil) {
            self.onClickDescription = onClickDescription
            self.descriptionLabel = descriptionLabel
            self.symbol = symbol
            self.label = label
            self.description = description
            self.disabled = disabled
            self.tooltip = tooltip
            _checked = checked
        }

        /// The label followed by `suffix`, and the description as styled runs.
        public func labelSuffix(_ suffix: some View) -> Root {
            var copy = self
            copy.labelSuffix = AnyView(suffix)
            return copy
        }

        public func descriptionRuns(_ runs: [CSSTextRun], onAction: @escaping (String) -> Void) -> Root {
            var copy = self
            copy.descriptionRuns = runs
            copy.onDescriptionAction = onAction
            return copy
        }

        public var body: some View {
            AxoBaseItem.Root(disabled: disabled) {
                if let symbol {
                    AxoBaseItem.Leading { AxoBaseItem.Icon(symbol: symbol) }
                }
                AxoBaseItem.Content {
                    if let labelSuffix {
                        AxoBaseItem.Label { HStack(spacing: 0) { AxoBaseItem.Text(label, type: .bodyMedium); labelSuffix } }
                    } else {
                        AxoBaseItem.Label(label)
                    }
                    if let descriptionRuns {
                        AxoBaseItem.Description(interactive: true) {
                            CSSText(runs: descriptionRuns, style: CSSTextStyle(AxoType.bodySmall), onTap: onDescriptionAction)
                        }
                    } else if let description {
                        if let onClickDescription {
                            AxoBaseItem.Description(interactive: true) {
                                SwiftUI.Button(action: onClickDescription) { AxoBaseItem.Text(description, type: .bodySmall) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(descriptionLabel ?? description)
                            }
                        } else {
                            AxoBaseItem.Description(description)
                        }
                    }
                    AxoBaseItem.Trailing {
                        AxoBaseItem.DescribedBy {
                            AxoSwitch.Root(checked: $checked, disabled: disabled, label: label)
                                .help(tooltip ?? "")
                        }
                    }
                }
            }
        }
    }
}
