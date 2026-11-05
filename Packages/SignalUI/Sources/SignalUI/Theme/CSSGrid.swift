// CSS grid with explicitly placed items and `auto` tracks (what upstream's stories and
// several panels use): each column/row is as wide/tall as its largest item (max-content);
// with `justify-content: normal` the auto columns then stretch equally to fill the
// container width.

import SwiftUI

struct CSSGridCellKey: LayoutValueKey { static let defaultValue = CSSGrid.Cell(row: 0, column: 0) }

extension View {
    /// `grid-row` / `grid-column` (0-based, span 1).
    public func gridCell(row: Int, column: Int) -> some View {
        layoutValue(key: CSSGridCellKey.self, value: CSSGrid.Cell(row: row, column: column))
    }
}

public struct CSSGrid: Layout {
    public struct Cell: Sendable, Hashable { public var row: Int, column: Int }
    public var columnGap: CGFloat
    public var rowGap: CGFloat
    public var stretchColumns: Bool

    public init(columnGap: CGFloat = 0, rowGap: CGFloat = 0, stretchColumns: Bool = true) {
        self.columnGap = columnGap
        self.rowGap = rowGap
        self.stretchColumns = stretchColumns
    }

    func tracks(_ subviews: Subviews, width: CGFloat?) -> (cols: [CGFloat], rows: [CGFloat]) {
        let cells = subviews.map { $0[CSSGridCellKey.self] }
        let nCols = (cells.map(\.column).max() ?? -1) + 1, nRows = (cells.map(\.row).max() ?? -1) + 1
        var cols = [CGFloat](repeating: 0, count: nCols)
        for (s, c) in zip(subviews, cells) { cols[c.column] = max(cols[c.column], s.sizeThatFits(.unspecified).width) }
        if stretchColumns, let width, nCols > 0 {
            let free = width - cols.reduce(0, +) - columnGap * CGFloat(nCols - 1)
            if free > 0 { cols = cols.map { $0 + free / CGFloat(nCols) } }
        }
        var rows = [CGFloat](repeating: 0, count: nRows)
        for (s, c) in zip(subviews, cells) {
            rows[c.row] = max(rows[c.row], s.sizeThatFits(ProposedViewSize(width: cols[c.column], height: nil)).height)
        }
        return (cols, rows)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (cols, rows) = tracks(subviews, width: proposal.width)
        let w = cols.reduce(0, +) + columnGap * CGFloat(max(0, cols.count - 1))
        let h = rows.reduce(0, +) + rowGap * CGFloat(max(0, rows.count - 1))
        return CGSize(width: max(w, proposal.width ?? 0), height: h)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (cols, rows) = tracks(subviews, width: bounds.width)
        func offset(_ tracks: [CGFloat], _ i: Int, _ gap: CGFloat) -> CGFloat { tracks.prefix(i).reduce(0, +) + gap * CGFloat(i) }
        for s in subviews {
            let c = s[CSSGridCellKey.self]
            // Grid items stretch to fill their cell (justify/align-self: normal).
            s.place(at: CGPoint(x: bounds.minX + offset(cols, c.column, columnGap), y: bounds.minY + offset(rows, c.row, rowGap)),
                    proposal: ProposedViewSize(width: cols[c.column], height: rows[c.row]))
        }
    }
}
