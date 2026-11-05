// Port of ts/axo/AxoAlertDialog.dom.tsx (Radix AlertDialog): a 288-wide alert with a
// title, description and equal-width actions; Cancel takes the initial focus.

import SwiftUI

public enum AxoAlertDialog {
    /// `<AxoAlertDialog.Content>` (w-72): present inside `AxoBaseDialog.Host`.
    public struct Content<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            AxoBaseDialog.Panel(width: 288, content: VStack(spacing: 0) { inner })
                .accessibilityAddTraits(.isModal)
                .modifier(HiddenTitleLabel())
        }
    }

    /// `<AxoAlertDialog.Body>`: flex flex-col gap-1 px-6 pt-5, scrolling beyond 440.
    public struct Body<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            let content = VStack(alignment: .leading, spacing: 4) { inner }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
            AxoDialog.HeightLimited(maxHeight: 440) {
                content
                AxoDialog.AxoScrollContainer { content }
            }
        }
    }

    /// `<AxoAlertDialog.Title>`: type-title-small text-primary (or screen-reader only).
    public struct Title: View {
        let text: String
        let screenReaderOnly: Bool
        public init(_ text: String, screenReaderOnly: Bool = false) {
            self.text = text
            self.screenReaderOnly = screenReaderOnly
        }
        public var body: some View {
            if screenReaderOnly {
                // sr-only is absolutely positioned (no flex item, no gap): no layout presence,
                // the title still labels the dialog for VoiceOver.
                EmptyView().preference(key: HiddenTitleKey.self, value: text)
            } else {
                CSSText(text, type: .titleSmall, color: .labelPrimary).accessibilityAddTraits(.isHeader)
            }
        }
    }

    struct HiddenTitleKey: PreferenceKey {
        static let defaultValue: String? = nil
        static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
    }

    struct HiddenTitleLabel: ViewModifier {
        @State var title: String?
        func body(content: Self.Content) -> some View {
            content.onPreferenceChange(HiddenTitleKey.self) { title = $0 }
                .accessibilityLabel(title ?? "")
        }
    }

    /// `<AxoAlertDialog.Description>`
    public struct Description: View {
        let runs: [CSSTextRun]
        let onTap: ((String) -> Void)?
        public init(_ text: String) {
            runs = [CSSTextRun(text)]
            onTap = nil
        }
        /// A description with styled runs (links, strong text); `onTap` gets a run's action.
        public init(runs: [CSSTextRun], onTap: ((String) -> Void)? = nil) {
            self.runs = runs
            self.onTap = onTap
        }
        public var body: some View { CSSText(runs: runs, style: CSSTextStyle(AxoType.bodyMedium), onTap: onTap) }
    }

    /// `<AxoAlertDialog.Footer>`: flex-wrap-reverse gap-2 p-4, equal-basis actions.
    public struct Footer<Inner: View>: View {
        let inner: Inner
        public init(@ViewBuilder content: () -> Inner) { inner = content() }
        public var body: some View {
            AxoButton.Group { inner }.padding(16)
        }
    }

    /// `<AxoAlertDialog.Cancel>`: auto-focused, like Radix's AlertDialog.Cancel.
    public struct Cancel: View {
        let label: String
        let disabled: Bool
        let autoFocus: Bool
        let action: () -> Void
        @Environment(\.dismiss) var dismiss
        /// - Parameter autoFocus: Radix focuses Cancel unless another control has autoFocus.
        public init(_ label: String? = nil, disabled: Bool = false, autoFocus: Bool = true, action: @escaping () -> Void = {}) {
            self.label = label ?? "Cancel"
            self.disabled = disabled
            self.autoFocus = autoFocus
            self.action = action
        }
        public var body: some View {
            AxoButton.Root(label, variant: .subtleSecondary, size: .md, width: .grow, disabled: disabled, autoFocus: autoFocus) {
                action()
                dismiss()
            }
        }
    }

    /// `<AxoAlertDialog.Ok>`
    public struct Ok: View {
        let label: String
        let disabled: Bool
        let autoFocus: Bool
        let action: () -> Void
        @Environment(\.dismiss) var dismiss
        /// - Parameter autoFocus: Radix focuses the first button; Ok is the only one where it is used.
        public init(_ label: String? = nil, disabled: Bool = false, autoFocus: Bool = true, action: @escaping () -> Void = {}) {
            self.label = label ?? "OK"
            self.disabled = disabled
            self.autoFocus = autoFocus
            self.action = action
        }
        public var body: some View {
            AxoButton.Root(label, variant: .strongPrimary, size: .md, width: .grow, disabled: disabled, autoFocus: autoFocus) {
                action()
                dismiss()
            }
        }
    }

    /// `<AxoAlertDialog.Action>`
    public struct Action: View {
        let label: String
        let variant: AxoDialog.ActionVariant
        let symbol: AxoSymbol.Name?
        let arrow: AxoButton.Arrow?
        let pending: Bool
        let disabled: Bool
        let autoFocus: Bool
        let labelRuns: [CSSTextRun]?
        let action: () -> Void
        public init(_ label: String, variant: AxoDialog.ActionVariant, symbol: AxoSymbol.Name? = nil, arrow: AxoButton.Arrow? = nil,
                    pending: Bool = false, disabled: Bool = false, autoFocus: Bool = false, labelRuns: [CSSTextRun]? = nil,
                    action: @escaping () -> Void) {
            self.labelRuns = labelRuns
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
                           autoFocus: autoFocus, labelRuns: labelRuns, action: action)
        }
    }
}
