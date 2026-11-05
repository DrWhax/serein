// Port of ts/axo/aria/AriaLabelled.dom.tsx: a `Target` named by the `Label`s and described
// by the `Description`s rendered inside the `Root` (upstream: aria-labelledby /
// aria-describedby over registered element ids, in document order). Here the labels' and
// descriptions' texts are collected by preference and become the target's accessibility
// label and hint. By default Label and Description are plain blocks of the inherited text.

import SwiftUI

public enum AriaLabelled {
    struct LabelsKey: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
    }
    struct DescriptionsKey: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
    }

    /// `<AriaLabelled.Root>`: should contain a `Target`, and its `Label`s and `Description`s.
    public struct Root<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { content }
    }

    /// `<AriaLabelled.Target>`: the element the labels name (one accessibility element).
    public struct Target<Content: View>: View {
        let content: Content
        @State private var labels: [String] = []
        @State private var descriptions: [String] = []
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            content
                .onPreferenceChange(LabelsKey.self) { labels = $0 }
                .onPreferenceChange(DescriptionsKey.self) { descriptions = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(labels.joined(separator: " "))
                .accessibilityHint(descriptions.joined(separator: " "))
        }
    }

    /// `<AriaLabelled.Label>`: a block of the inherited text, or (`asChild`) custom content.
    public struct Label<Content: View>: View {
        let text: String
        let content: Content
        public init(_ text: String, @ViewBuilder asChild content: () -> Content) {
            self.text = text
            self.content = content()
        }
        public var body: some View { content.preference(key: LabelsKey.self, value: [text]) }
    }

    /// `<AriaLabelled.Description>`: as `Label`, for the description.
    public struct Description<Content: View>: View {
        let text: String
        let content: Content
        public init(_ text: String, @ViewBuilder asChild content: () -> Content) {
            self.text = text
            self.content = content()
        }
        public var body: some View { content.preference(key: DescriptionsKey.self, value: [text]) }
    }

    /// The default element: a full-width block of the inherited (body-large) text.
    @MainActor static func block(_ text: String) -> some View {
        CSSText(text, type: .bodyLarge).frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AriaLabelled.Label where Content == AnyView {
    public init(_ text: String) { self.init(text) { AnyView(AriaLabelled.block(text)) } }
}

extension AriaLabelled.Description where Content == AnyView {
    public init(_ text: String) { self.init(text) { AnyView(AriaLabelled.block(text)) } }
}
