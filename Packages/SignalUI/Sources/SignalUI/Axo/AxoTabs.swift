// Port of ts/axo/AxoTabs.dom.tsx: tabs (Radix Tabs) whose list is a full-width,
// equal-width, track-less ExperimentalAxoBaseSegmentedControl.

import SwiftUI

public enum AxoTabs {
    struct Context {
        var value: Binding<String>
    }

    struct ContextKey: EnvironmentKey {
        static let defaultValue: Context? = nil
    }

    /// `<AxoTabs.Root>`: `flex flex-col`.
    public struct Root<Content: View>: View {
        @Binding var value: String
        let content: Content

        public init(value: Binding<String>, @ViewBuilder content: () -> Content) {
            self._value = value
            self.content = content()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.axoTabs, Context(value: $value))
        }
    }

    /// `<AxoTabs.List>`
    public struct List<Content: View>: View {
        let content: Content
        @Environment(\.axoTabs) var context

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            ExperimentalAxoBaseSegmentedControl.Root(value: context.map { .single($0.value.wrappedValue) } ?? .none, variant: .noTrack,
                                                     width: .full, itemWidth: .equal) { content }
                .accessibilityElement(children: .contain)
        }
    }

    /// `<AxoTabs.Trigger>`
    public struct Trigger: View {
        let value: String
        let label: String
        @Environment(\.axoTabs) var context

        public init(value: String, _ label: String) {
            self.value = value
            self.label = label
        }

        public var body: some View {
            ExperimentalAxoBaseSegmentedControl.Item(value: value, action: { context?.value.wrappedValue = value }) {
                ExperimentalAxoBaseSegmentedControl.ItemText(label)
            }
            .accessibilityAddTraits(.isButton)
        }
    }

    /// `<AxoTabs.Content>`: shown only for the selected tab.
    public struct Content<Body: View>: View {
        let value: String
        let content: Body
        @Environment(\.axoTabs) var context

        public init(value: String, @ViewBuilder content: () -> Body) {
            self.value = value
            self.content = content()
        }

        public var body: some View {
            if context?.value.wrappedValue == value { content }
        }
    }
}

extension EnvironmentValues {
    var axoTabs: AxoTabs.Context? {
        get { self[AxoTabs.ContextKey.self] }
        set { self[AxoTabs.ContextKey.self] = newValue }
    }
}
