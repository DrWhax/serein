// Port of ts/axo/AxoSegmentedControl.dom.tsx: a row of mutually-exclusive buttons (Radix
// ToggleGroup, type="single") drawn by ExperimentalAxoBaseSegmentedControl.

import SwiftUI

public enum ExperimentalAxoSegmentedControl {
    public typealias Variant = ExperimentalAxoBaseSegmentedControl.Variant
    public typealias RootWidth = ExperimentalAxoBaseSegmentedControl.RootWidth
    public typealias ItemWidth = ExperimentalAxoBaseSegmentedControl.ItemWidth

    struct SelectionKey: EnvironmentKey {
        static let defaultValue: Binding<String?> = .constant(nil)
    }

    /// `<AxoSegmentedControl.Root>`: pressing the pressed item un-presses it (value `nil`).
    public struct Root<Content: View>: View {
        let label: String?
        let width: RootWidth
        let itemWidth: ItemWidth
        let variant: Variant
        @Binding var value: String?
        let content: Content

        public init(label: String?, width: RootWidth, itemWidth: ItemWidth, variant: Variant, value: Binding<String?>,
                    @ViewBuilder content: () -> Content) {
            self.label = label
            self.width = width
            self.itemWidth = itemWidth
            self.variant = variant
            self._value = value
            self.content = content()
        }

        public var body: some View {
            ExperimentalAxoBaseSegmentedControl.Root(value: value.map { .single($0) } ?? .none, variant: variant, width: width,
                                                     itemWidth: itemWidth) { content }
                .environment(\.axoSegmentedControlSelection, $value)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label ?? "")
        }
    }

    /// `<AxoSegmentedControl.Item>`
    public struct Item<Content: View>: View {
        let value: String
        let content: Content
        @Environment(\.axoSegmentedControlSelection) var selection

        public init(value: String, @ViewBuilder content: () -> Content) {
            self.value = value
            self.content = content()
        }

        public var body: some View {
            ExperimentalAxoBaseSegmentedControl.Item(value: value, action: {
                selection.wrappedValue = selection.wrappedValue == value ? nil : value
            }) { content }
        }
    }

    /// `<AxoSegmentedControl.ItemText>`
    public typealias ItemText = ExperimentalAxoBaseSegmentedControl.ItemText

    /// `<AxoSegmentedControl.ItemBadge>`
    public typealias ItemBadge = ExperimentalAxoBaseSegmentedControl.ItemBadge
}

extension EnvironmentValues {
    var axoSegmentedControlSelection: Binding<String?> {
        get { self[ExperimentalAxoSegmentedControl.SelectionKey.self] }
        set { self[ExperimentalAxoSegmentedControl.SelectionKey.self] = newValue }
    }
}
