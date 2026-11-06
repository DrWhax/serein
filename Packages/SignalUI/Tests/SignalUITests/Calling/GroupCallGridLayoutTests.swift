import Foundation
import Testing
@testable import SignalUI

/// GroupCallGridLayout against the tile rects of CallScreen--group-call-many-paginated (75
/// participants, random aspect ratios: the first page's are read back from the capture's
/// tile sizes; the 49 + "next" tiles must land where Chromium put them).
@Suite struct GroupCallGridLayoutTests {
    /// (isPagination, x, y, width, height) in the 1168×738 grid, from the capture's DOM.
    static let expected: [(Bool, Double, Double, Double, Double)] = [(false, 8, 51, 125, 96), (false, 145, 51, 125, 96), (false, 282, 51, 61, 96), (false, 355, 51, 125, 96), (false, 492, 51, 125, 96), (false, 629, 51, 125, 96), (false, 766, 51, 125, 96), (false, 903, 51, 125, 96), (false, 1040, 51, 125, 96), (false, 26, 159, 125, 96), (false, 163, 159, 125, 96), (false, 300, 159, 67, 96), (false, 379, 159, 125, 96), (false, 516, 159, 125, 96), (false, 653, 159, 125, 96), (false, 790, 159, 125, 96), (false, 927, 159, 83, 96), (false, 1022, 159, 125, 96), (false, 4, 267, 125, 96), (false, 141, 267, 125, 96), (false, 278, 267, 125, 96), (false, 415, 267, 125, 96), (false, 552, 267, 125, 96), (false, 689, 267, 69, 96), (false, 770, 267, 125, 96), (false, 907, 267, 125, 96), (false, 1044, 267, 125, 96), (false, 47, 375, 77, 96), (false, 136, 375, 125, 96), (false, 273, 375, 125, 96), (false, 410, 375, 125, 96), (false, 547, 375, 95, 96), (false, 654, 375, 125, 96), (false, 791, 375, 60, 96), (false, 863, 375, 125, 96), (false, 1000, 375, 125, 96), (false, 0, 483, 125, 96), (false, 137, 483, 77, 96), (false, 226, 483, 125, 96), (false, 363, 483, 125, 96), (false, 500, 483, 125, 96), (false, 637, 483, 125, 96), (false, 774, 483, 125, 96), (false, 911, 483, 125, 96), (false, 1048, 483, 125, 96), (false, 345, 591, 60, 96), (false, 417, 591, 125, 96), (false, 554, 591, 68, 96), (false, 634, 591, 83, 96), (true, 729, 591, 96, 96)]

    @Test func paginatedFirstPage() {
        let tiles = Self.expected.filter { !$0.0 }
        let ps = (0..<75).map { i in
            GroupCallRemoteParticipantInfo(demuxId: UInt32(i), conversation: CallingConversation(id: "\(i)", title: "P\(i)"),
                                           videoAspectRatio: i < tiles.count ? tiles[i].3 / tiles[i].4 : 1.3)
        }
        let minHeight = GroupCallGridLayout.smallTilesMinHeight
        let maxRows = Int(738 / (minHeight + GroupCallGridLayout.margin))
        let pages = GroupCallGridLayout.pages(ps, maxRowWidth: 1168, minHeight: minHeight, maxRows: maxRows, maxPages: .max, currentPage: 0)
        #expect(pages.count == 2)
        let placed = GroupCallGridLayout.place(pages.first, width: 1168, height: 738, minHeight: minHeight, maxRows: maxRows).tiles
        #expect(placed.count == Self.expected.count)
        for (p, e) in zip(placed, Self.expected) {
            if case .pagination(let next, let count) = p.tile { #expect(e.0 && next && count == 26) } else { #expect(!e.0) }
            #expect(abs(p.frame.minX - e.1) <= 1 && abs(p.frame.minY - e.2) <= 1 && abs(p.frame.width - e.3) <= 1 && abs(p.frame.height - e.4) <= 1,
                    "\(p.frame) vs \(e)")
        }
    }
}
