// Ports of ts/components/PreferencesUtil.dom.tsx (the legacy Preferences.scss rows):
// SettingsRow (a fieldset with a bold legend, 20px bottom padding, a divider and 24px gap
// before the next), SettingsRadio (40px CircleCheckbox rows), and the page's back button.

import SwiftUI

public struct SettingsRow<Content: View>: View {
    let title: String?
    let isLast: Bool
    let minHeight: CGFloat?
    let content: Content

    public init(title: String? = nil, isLast: Bool = false, minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isLast = isLast
        self.minHeight = minHeight
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                CSSText(title, style: LegacyType.body1(weight: 600), color: .labelPrimary).padding(.horizontal, 24).accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `:not(:last-child)`: a 1px border-bottom (part of the row's height), then margin 24.
        .padding(.bottom, isLast ? 0 : 1)
        .frame(minHeight: minHeight, alignment: .top)
        .overlay(alignment: .bottom) { if !isLast { Rectangle().fill(AxoColor.borderPrimary).frame(height: 1) } }
        .padding(.bottom, isLast ? 0 : 24)
    }
}

public struct SettingsRadio<Value: Hashable>: View {
    public struct Option {
        public var text: String
        public var value: Value
        public var readOnly = false
        public var onClick: (() -> Void)?
        public init(text: String, value: Value, readOnly: Bool = false, onClick: (() -> Void)? = nil) {
            self.text = text
            self.value = value
            self.readOnly = readOnly
            self.onClick = onClick
        }
    }

    let value: Value
    let options: [Option]
    let onChange: (Value) -> Void

    public init(value: Value, options: [Option], onChange: @escaping (Value) -> Void) {
        self.value = value
        self.options = options
        self.onChange = onChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                HStack(spacing: 16) {
                    CircleCheckbox(variant: .small, checked: value == option.value, isRadio: true) { _ in
                        option.onClick?()
                        if !option.readOnly { onChange(option.value) }
                    }
                    CSSText(option.text, style: LegacyType.body1(), color: .labelPrimary)
                }
                .frame(height: 40)
                .opacity(option.readOnly ? 0.4 : 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    option.onClick?()
                    if !option.readOnly { onChange(option.value) }
                }
                .padding(.bottom, i == options.count - 1 ? 8 : 0)
            }
        }
        .padding(.horizontal, 24)
    }
}

/// `.Preferences__back-icon`: a 20px chevron 12px from the start, centred vertically.
struct PreferencesBackButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { SignalIcon("v3/chevron/chevron-left", size: 20, color: .labelPrimary, mask: true) }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .accessibilityLabel(label)
    }
}

/// `.Preferences__description` inside `.Preferences__padding`.
struct PreferencesDescription: View {
    let text: String
    var body: some View {
        CSSText(text, style: LegacyType.subtitle(), color: .labelSecondary).padding(.horizontal, 24)
    }
}

/// `SettingsControl` (`.Preferences__control`): the label (and description) at the start, the
/// control at the end; min-height 48, padding 4px 24px.
struct SettingsControl<Right: View>: View {
    let left: String
    let description: String?
    let right: Right

    init(left: String, description: String? = nil, @ViewBuilder right: () -> Right) {
        self.left = left
        self.description = description
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CSSText(left, style: LegacyType.body1(), color: .labelPrimary)
                if let description { CSSText(description, style: LegacyType.subtitle(), color: .labelSecondary) }
            }
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            right.cssTextColor(.labelSecondary).fixedSize()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 24)
        .frame(minHeight: 48)
    }
}
