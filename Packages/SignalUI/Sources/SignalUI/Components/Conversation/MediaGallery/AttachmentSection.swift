// Port of ts/components/conversation/media-gallery/AttachmentSection.dom.tsx: a dated section of
// the gallery. Media is a grid of 100–120px tiles, 4px apart (5 columns from a 560px content
// width, 4 from 455px, else 3) under a px-5 / ps-1 header; documents, audio and links are
// rows under a px-6 header.

import SwiftUI

public struct AttachmentSection<Content: View>: View {
    public enum Kind: Sendable { case media, list }
    let header: String?
    let kind: Kind
    let content: Content

    public init(header: String?, kind: Kind, @ViewBuilder content: () -> Content) {
        self.header = header
        self.kind = kind
        self.content = content()
    }

    public var body: some View {
        let headerStyle = CSSTextStyle(AxoType.bodyMedium.weight(600))
        switch kind {
        case .media:
            VStack(alignment: .leading, spacing: 0) {
                if let header {
                    CSSText(header, style: headerStyle, color: .labelPrimary)
                        .padding(.leading, 4).padding(.top, 16).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                MediaGridLayout(gap: 4) { content }
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
        case .list:
            VStack(alignment: .leading, spacing: 0) {
                if let header {
                    CSSText(header, style: headerStyle, color: .labelPrimary)
                        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) { content }
            }
        }
    }
}

/// `grid gap-1 grid-cols-[repeat(N, minmax(100px, 120px))]` with N from the container width.
struct MediaGridLayout: Layout {
    let gap: CGFloat
    func columns(_ width: CGFloat) -> (count: Int, side: CGFloat) {
        let n = width >= 560 ? 5 : width >= 455 ? 4 : 3
        let side = min(120, max(100, (width - gap * CGFloat(n - 1)) / CGFloat(n)))
        return (n, side)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 616
        let (n, side) = columns(width)
        let rows = (subviews.count + n - 1) / n
        return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * side + gap * CGFloat(rows - 1))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (n, side) = columns(bounds.width)
        for (i, s) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % n) * (side + gap), y = bounds.minY + CGFloat(i / n) * (side + gap)
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: side, height: side))
        }
    }
}
