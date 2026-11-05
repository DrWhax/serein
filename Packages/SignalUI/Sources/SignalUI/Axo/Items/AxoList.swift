// Port of ts/axo/items/AxoList.dom.tsx: a titled section around a card of items.
//
//   AxoList.Group (flex-col gap-4) > AxoList.Root (section)
//     > Header (px-4 py-2: Label, Description) > Body (curved-2xl card, p-1) > Footer (FooterDescription)

import SwiftUI

public enum AxoList {
    /// `<AxoList.Group>`: flex flex-col gap-4
    public struct Group<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            VStack(alignment: .leading, spacing: 16) { content }
        }
    }

    /// `<AxoList.Root>`: a `<section>` labelled by its `Label`.
    public struct Root<Content: View>: View {
        let accessibilityLabel: String?
        let content: Content
        public init(accessibilityLabel: String? = nil, @ViewBuilder content: () -> Content) {
            self.accessibilityLabel = accessibilityLabel
            self.content = content()
        }
        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel ?? "")
        }
    }

    /// `<AxoList.Header>`: px-4 py-2
    public struct Header<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `<AxoList.Label>`: h2 type-body-medium font-semibold text-primary
    public struct Label: View {
        let pieces: [AxoInlinePiece]
        public init(_ text: String) { self.pieces = [.text(text)] }
        /// Mixed inline content: text and symbol glyphs (in font-regular).
        public init(pieces: [AxoInlinePiece]) { self.pieces = pieces }
        public var body: some View {
            Group {
                if pieces.count == 1, case .text(let text) = pieces[0] {
                    AxoBaseItem.Text(text, type: AxoType.bodyMedium.weight(600))
                } else {
                    AxoInlineFlowText(pieces: pieces, style: CSSTextStyle(AxoType.bodyMedium.weight(600)), alignment: .start, maxLines: nil) { _ in }
                }
            }
            .cssTextColor(.labelPrimary)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// `<AxoList.Description>`: p type-body-small text-secondary
    public struct Description: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View {
            AxoBaseItem.Text(text, type: .bodySmall)
                .cssTextColor(.labelSecondary)
        }
    }

    /// `<AxoList.Body>`: min-w-fit curved-2xl bg-surface-card p-1 shadow-elevation-0
    public struct Body<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            let shape = SuperellipseRect.curved(AxoRadius._2xl)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { SnappedShapeFill(shape: shape, color: AxoColor.surfaceCard) }
                .axoShadow(.shadowElevation0, in: shape)
        }
    }

    /// `<AxoList.Footer>`: px-4 py-2
    public typealias Footer = Header

    /// `<AxoList.FooterDescription>`: p type-body-small text-secondary
    public typealias FooterDescription = Description
}
