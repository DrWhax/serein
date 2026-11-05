// CSS flexbox as a SwiftUI Layout (CSS Flexible Box Layout §9, single- and multi-line),
// so upstream's flex markup ports one-to-one: items keep their flex-basis (content size by
// default), grow and shrink by their factors, clamp to min/max sizes (min-width: auto is
// the content's minimum size), wrap into lines, and are justified/aligned per line.

import SwiftUI

public struct CSSFlexItem: Sendable, Hashable {
    public var grow: CGFloat = 0
    public var shrink: CGFloat = 1
    /// nil = auto (content size)
    public var basis: CGFloat?
    /// nil = auto (content minimum: the size when proposed zero, as min-content)
    public var minMain: CGFloat?
    public var maxMain: CGFloat?
    /// `max-width: calc(100% - inset)`: a maximum relative to the container's main size.
    public var maxMainInset: CGFloat?
    public var alignSelf: CSSFlex.Align?
    /// `margin-inline-start: auto` (`ms-auto`): absorbs the line's free space before it.
    public var autoMarginStart: Bool = false
    public init(grow: CGFloat = 0, shrink: CGFloat = 1, basis: CGFloat? = nil, minMain: CGFloat? = nil, maxMain: CGFloat? = nil,
                alignSelf: CSSFlex.Align? = nil, autoMarginStart: Bool = false, maxMainInset: CGFloat? = nil) {
        self.maxMainInset = maxMainInset
        self.autoMarginStart = autoMarginStart
        self.grow = grow
        self.shrink = shrink
        self.basis = basis
        self.minMain = minMain
        self.maxMain = maxMain
        self.alignSelf = alignSelf
    }
}

struct CSSFlexItemKey: LayoutValueKey { static let defaultValue = CSSFlexItem() }

extension View {
    /// Flex item properties (`grow`, `shrink-0`, `basis-*`, `min-w-0`, `self-*`).
    public func flexItem(grow: CGFloat = 0, shrink: CGFloat = 1, basis: CGFloat? = nil, minMain: CGFloat? = nil, maxMain: CGFloat? = nil,
                         alignSelf: CSSFlex.Align? = nil, autoMarginStart: Bool = false, maxMainInset: CGFloat? = nil) -> some View {
        layoutValue(key: CSSFlexItemKey.self, value: CSSFlexItem(grow: grow, shrink: shrink, basis: basis, minMain: minMain, maxMain: maxMain,
                                                                 alignSelf: alignSelf, autoMarginStart: autoMarginStart, maxMainInset: maxMainInset))
    }
}

public struct CSSFlex: Layout {
    public enum Direction: Sendable { case row, column }
    public enum Justify: Sendable { case start, center, end, spaceBetween, spaceAround, spaceEvenly }
    public enum Align: Sendable, Hashable { case start, center, end, stretch }

    public var direction: Direction
    public var wrap: Bool
    public var gap: CGFloat          // main-axis gap between items
    public var crossGap: CGFloat     // gap between lines
    public var justify: Justify
    public var align: Align
    public var reverseLines: Bool    // flex-wrap: wrap-reverse
    /// Shrink-to-fit container (absolutely positioned, inline-flex, floats): its main size
    /// is its content's, capped by the proposal, instead of the full proposed width.
    public var fitContent: Bool = false

    public init(_ direction: Direction = .row, wrap: Bool = false, gap: CGFloat = 0, crossGap: CGFloat? = nil, justify: Justify = .start,
                align: Align = .stretch, reverseLines: Bool = false, fitContent: Bool = false) {
        self.fitContent = fitContent
        self.direction = direction
        self.wrap = wrap
        self.gap = gap
        self.crossGap = crossGap ?? gap
        self.justify = justify
        self.align = align
        self.reverseLines = reverseLines
    }

    struct Line {
        var items: [Int]
        var main: [CGFloat]
        var cross: CGFloat
    }

    func mainOf(_ s: CGSize) -> CGFloat { direction == .row ? s.width : s.height }
    func crossOf(_ s: CGSize) -> CGFloat { direction == .row ? s.height : s.width }
    func proposal(main: CGFloat?, cross: CGFloat?) -> ProposedViewSize {
        direction == .row ? ProposedViewSize(width: main, height: cross) : ProposedViewSize(width: cross, height: main)
    }

    func hypothetical(_ s: LayoutSubview, available: CGFloat?) -> (basis: CGFloat, min: CGFloat, max: CGFloat) {
        let item = s[CSSFlexItemKey.self]
        var maxMain = item.maxMain ?? .infinity
        if let inset = item.maxMainInset, let available { maxMain = min(maxMain, max(0, available - inset)) }
        let content = mainOf(s.sizeThatFits(proposal(main: nil, cross: nil)))
        let minContent = item.minMain ?? min(content, mainOf(s.sizeThatFits(proposal(main: 0, cross: nil))))
        return (item.basis ?? content, minContent, maxMain)
    }

    /// §9.7 Resolving flexible lengths for one line.
    func resolve(_ idx: [Int], _ subviews: Subviews, available: CGFloat?) -> [CGFloat] {
        let h = idx.map { hypothetical(subviews[$0], available: available) }
        var size = h.map { min(max($0.basis, $0.min), $0.max) }
        guard let available else { return size }
        let gaps = gap * CGFloat(max(0, idx.count - 1))
        let initialFree = available - gaps - h.map(\.basis).reduce(0, +)
        let growing = initialFree > 0
        var frozen = idx.indices.map { i in
            let f = subviews[idx[i]][CSSFlexItemKey.self]
            return (growing ? f.grow : f.shrink) == 0 || (growing && h[i].basis > size[i]) || (!growing && h[i].basis < size[i])
        }
        var target = h.map(\.basis)
        for _ in 0..<(idx.count + 1) {
            let open = idx.indices.filter { !frozen[$0] }
            if open.isEmpty { break }
            let used = idx.indices.map { frozen[$0] ? size[$0] : h[$0].basis }.reduce(0, +)
            let free = available - gaps - used
            for i in open {
                let f = subviews[idx[i]][CSSFlexItemKey.self]
                if growing {
                    let total = open.map { subviews[idx[$0]][CSSFlexItemKey.self].grow }.reduce(0, +)
                    target[i] = h[i].basis + (total > 0 ? free * f.grow / max(total, 1) : 0)
                } else {
                    let scaled = open.map { subviews[idx[$0]][CSSFlexItemKey.self].shrink * h[$0].basis }.reduce(0, +)
                    target[i] = h[i].basis + (scaled > 0 ? free * f.shrink * h[i].basis / scaled : 0)
                }
            }
            var violation: CGFloat = 0
            var clamped = target
            for i in open { clamped[i] = min(max(target[i], h[i].min), h[i].max); violation += clamped[i] - target[i] }
            for i in open {
                if violation == 0 || (violation > 0 && clamped[i] > target[i]) || (violation < 0 && clamped[i] < target[i]) {
                    frozen[i] = true
                }
                size[i] = clamped[i]
            }
            if violation == 0 { break }
        }
        return size
    }

    func lines(_ subviews: Subviews, available: CGFloat?, crossProposal: CGFloat?) -> [Line] {
        var groups: [[Int]] = []
        if wrap, let available {
            var cur: [Int] = []
            var used: CGFloat = 0
            for i in subviews.indices {
                let h = hypothetical(subviews[i], available: available)
                let outer = min(max(h.basis, h.min), h.max)
                if !cur.isEmpty && used + gap + outer > available + 0.01 {
                    groups.append(cur)
                    cur = []
                    used = 0
                }
                used += (cur.isEmpty ? 0 : gap) + outer
                cur.append(i)
            }
            if !cur.isEmpty { groups.append(cur) }
        } else {
            groups = [Array(subviews.indices)]
        }
        return groups.map { idx in
            let main = resolve(idx, subviews, available: available)
            let cross = zip(idx, main).map { i, m in crossOf(subviews[i].sizeThatFits(proposal(main: m, cross: nil))) }.max() ?? 0
            return Line(items: idx, main: main, cross: (!wrap ? crossProposal : nil) ?? cross)
        }
    }

    public func sizeThatFits(proposal p: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableMain = direction == .row ? p.width : p.height
        let crossProposal = direction == .row ? p.height : p.width
        let ls = lines(subviews, available: availableMain, crossProposal: nil)
        let contentMain = ls.map { $0.main.reduce(0, +) + gap * CGFloat(max(0, $0.items.count - 1)) }.max() ?? 0
        let main = fitContent ? min(availableMain ?? contentMain, contentMain) : (availableMain ?? contentMain)
        var cross = ls.map(\.cross).reduce(0, +) + crossGap * CGFloat(max(0, ls.count - 1))
        if align == .stretch, !wrap, let crossProposal, direction == .column { cross = max(cross, crossProposal) }
        return direction == .row ? CGSize(width: main, height: cross) : CGSize(width: cross, height: main)
    }

    public func placeSubviews(in bounds: CGRect, proposal p: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let availableMain = mainOf(bounds.size)
        let ls = lines(subviews, available: availableMain, crossProposal: wrap ? nil : crossOf(bounds.size))
        var crossCursor: CGFloat = 0
        let ordered = reverseLines ? Array(ls.reversed()) : ls
        let totalCross = ls.map(\.cross).reduce(0, +) + crossGap * CGFloat(max(0, ls.count - 1))
        if reverseLines { crossCursor = crossOf(bounds.size) - totalCross }
        for line in ordered {
            let used = line.main.reduce(0, +) + gap * CGFloat(max(0, line.items.count - 1))
            let free = availableMain - used
            let n = CGFloat(line.items.count)
            var cursor: CGFloat
            var between = gap
            let autoMargins = line.items.filter { subviews[$0][CSSFlexItemKey.self].autoMarginStart }.count
            let marginShare = autoMargins > 0 ? max(0, free) / CGFloat(autoMargins) : 0
            switch autoMargins > 0 ? .start : justify {
            case .start: cursor = 0
            case .center: cursor = free / 2
            case .end: cursor = free
            case .spaceBetween: cursor = 0; if n > 1, free > 0 { between = gap + free / (n - 1) }
            case .spaceAround: cursor = free > 0 ? free / n / 2 : 0; if free > 0 { between = gap + free / n }
            case .spaceEvenly: cursor = free > 0 ? free / (n + 1) : 0; if free > 0 { between = gap + free / (n + 1) }
            }
            for (k, i) in line.items.enumerated() {
                let s = subviews[i]
                let m = line.main[k]
                if s[CSSFlexItemKey.self].autoMarginStart { cursor += marginShare }
                let a = s[CSSFlexItemKey.self].alignSelf ?? align
                let natural = crossOf(s.sizeThatFits(proposal(main: m, cross: a == .stretch ? line.cross : nil)))
                let c = a == .stretch ? line.cross : natural
                let off: CGFloat
                switch a {
                case .start, .stretch: off = 0
                case .center: off = (line.cross - c) / 2
                case .end: off = line.cross - c
                }
                let point = direction == .row
                    ? CGPoint(x: bounds.minX + cursor, y: bounds.minY + crossCursor + off)
                    : CGPoint(x: bounds.minX + crossCursor + off, y: bounds.minY + cursor)
                s.place(at: point, proposal: proposal(main: m, cross: c))
                cursor += m + between
            }
            crossCursor += line.cross + crossGap
        }
    }
}

/// CSS shrink-to-fit width (a flex item with `flex: 0 1 auto` in a row, or an abspos /
/// float box): the child's max-content width, capped at the proposed width.
public struct CSSShrinkToFit: Layout {
    public init() {}
    func width(_ subviews: Subviews, _ proposal: ProposedViewSize) -> CGFloat? {
        guard let first = subviews.first else { return nil }
        let maxContent = first.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width
        return proposal.width.map { min($0, maxContent) } ?? maxContent
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let w = width(subviews, proposal)
        let size = first.sizeThatFits(ProposedViewSize(width: w, height: proposal.height))
        return CGSize(width: w ?? size.width, height: size.height)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height)) }
    }
}
