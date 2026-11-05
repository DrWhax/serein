// Port of ts/axo/chat/AxoChatDateSection.dom.tsx: a section of the chat timeline under a
// date header that sticks to the top of the scroll area (sticky -top-0.5). Once stuck
// (scrolled ≥ 2pt under the top) the header pill gets the material background, primary
// text and elevation-1 shadow.

import SwiftUI

public enum AxoChatDateSection {
    /// `<AxoChatDateSection.Root>`: a section; its Header sticks within it.
    public struct Root<Content: View>: View {
        let content: Content
        @State private var height: CGFloat = 0

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .environment(\.axoChatDateSectionHeight, height)
                .accessibilityElement(children: .contain)
        }
    }

    /// `<AxoChatDateSection.Header>`: flex justify-center px-4 py-2.5 around an
    /// `h3.px-3.py-1.text-center.type-body-small.font-semibold.text-secondary.truncate.rounded-full`.
    public struct Header: View {
        let label: String
        @Environment(\.axoChatDateSectionHeight) var sectionHeight
        @Environment(\.axoStaticRendering) var staticRendering

        public init(_ label: String) {
            self.label = label
        }

        func pill(stuck: Bool) -> some View {
            CSSText(label, type: AxoType.bodySmall.weight(600), wrap: .truncate, alignment: .center,
                    color: stuck ? .labelPrimary : .labelSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background { if stuck { Capsule().fill(AxoColor.materialPrimary) } }
                .modifier(StuckShadow(on: stuck))
        }

        public var body: some View {
            let header = ZStack {
                pill(stuck: false)
                if !staticRendering {
                    // The stuck look, faded in by the scroll position (visualEffect below).
                    pill(stuck: true).visualEffect { content, proxy in
                        content.opacity((proxy.frame(in: .scrollView(axis: .vertical)).minY < -2) ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityAddTraits(.isHeader)
            .zIndex(10)
            if staticRendering {
                header
            } else {
                let limit = sectionHeight
                header.visualEffect { content, proxy in
                    // sticky -top-0.5, bounded by the section.
                    let frame = proxy.frame(in: .scrollView(axis: .vertical))
                    let offset = max(0, min(-2 - frame.minY, limit - frame.height))
                    return content.offset(y: offset)
                }
            }
        }
    }

    struct StuckShadow: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.axoShadow(.shadowElevation1, in: Capsule()) } else { content }
        }
    }
}

extension EnvironmentValues {
    @Entry var axoChatDateSectionHeight: CGFloat = 0
}
