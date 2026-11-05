// Port of ts/axo/chatList/AxoChatList.dom.tsx (+ AxoChatList.css): the sidebar chat list,
// full or compact, with labelled groups and empty / loading states.
//
//   <AxoChatList.Root compact>
//     <AxoChatItem.Root/> | <AxoChatItemCompact.Root/>
//     <AxoChatList.Group> <AxoChatList.Label/> items… </AxoChatList.Group>
//   </AxoChatList.Root>

import SwiftUI

public enum AxoChatList {
    /// `<AxoChatList.Root compact>`
    public struct Root<Content: View>: View {
        let compact: Bool
        let content: Content

        public init(compact: Bool = false, @ViewBuilder content: () -> Content) {
            self.compact = compact
            self.content = content()
        }

        public var body: some View {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .environment(\.axoChatListCompact, compact)
                .accessibilityElement(children: .contain)
        }
    }

    /// `<AxoChatList.Group>`
    public struct Group<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            VStack(spacing: 0) { content }.accessibilityElement(children: .contain)
        }
    }

    /// `<AxoChatList.Label>`: flex h-10 items-end px-6 pb-2 truncate type-title-small
    /// text-primary; compact lists show a divider instead (the text stays for VoiceOver):
    /// mx-auto my-4.75 h-0.5 w-10 rounded-full bg-secondary.
    public struct Label: View {
        let text: String
        @Environment(\.axoChatListCompact) var compact

        public init(_ text: String) {
            self.text = text
        }

        public var body: some View {
            Group {
                if compact {
                    Capsule().fill(AxoColor.fillSecondary)
                        .frame(width: 40, height: 2)
                        .padding(.vertical, 19)
                        .frame(maxWidth: .infinity)
                } else {
                    CSSText(text, type: .titleSmall, wrap: .truncate, color: .labelPrimary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .bottomLeading)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// flex items-center justify-center px-3 py-12 text-center type-body-medium text-secondary
    struct StateBox<Content: View>: View {
        let content: Content
        var body: some View {
            content
                .cssTextColor(.labelSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
        }
    }

    /// `<AxoChatList.EmptyState>`
    public struct EmptyState: View {
        let text: String

        public init(_ text: String) {
            self.text = text
        }

        public var body: some View {
            StateBox(content: CSSText(text, type: .bodyMedium, alignment: .center))
        }
    }

    /// `<AxoChatList.LoadingState>`
    public struct LoadingState<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            StateBox(content: content)
        }
    }
}

extension EnvironmentValues {
    @Entry var axoChatListCompact: Bool = false
}
