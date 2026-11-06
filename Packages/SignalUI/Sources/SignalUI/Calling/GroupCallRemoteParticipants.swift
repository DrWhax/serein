// Port of ts/components/GroupCallRemoteParticipants.dom.tsx + GroupCallOverflowArea.dom.tsx:
// the group-call grid. Participants (presenter, then most recent speaker first) are packed
// into rows at the minimum tile height (80px paginated, 200px otherwise), page by page with
// "+N" pagination tiles; the rows are then rearranged for the largest scale that fits, and
// centred. In speaker view only the first participant is in the grid; the rest (or, outside
// pagination, whoever doesn't fit) go to the 107px overflow column on the right.

import SignalI18n
import SwiftUI

/// A tile in the grid: a participant or a "+N" pagination button.
public enum GroupCallGridTile: Hashable, Sendable {
    case participant(GroupCallRemoteParticipantInfo)
    case pagination(next: Bool, count: Int)

    var aspectRatio: Double {
        switch self {
        case .participant(let p): p.videoAspectRatio ?? 1
        case .pagination: 1      // PAGINATION_BUTTON_ASPECT_RATIO
        }
    }
}

public enum GroupCallGridLayout {
    public static let smallTilesMinHeight: Double = 80, largeTilesMinHeight: Double = 200
    public static let margin: Double = 12
    public static let maxParticipantsPerPage = 49
    public static let overflowWidth: Double = 107

    public struct Page: Equatable {
        public var rows: [[GroupCallGridTile]]
        public var numParticipants: Int
    }

    public struct Placed: Equatable {
        public var tile: GroupCallGridTile
        public var frame: CGRect
    }

    static func rowWidth(_ row: [GroupCallGridTile], _ h: Double) -> Double { row.reduce(0) { $0 + $1.aspectRatio * h } }

    /// `getNextPage`
    static func nextPage(_ participants: [GroupCallRemoteParticipantInfo], maxRowWidth: Double, minHeight: Double, maxRows: Int, maxPerPage: Int,
                         roomForPrev: Bool, roomForNext: Bool, isSubset: Bool = false) -> Page {
        let button = minHeight
        var width = roomForPrev ? button + margin : 0
        var rows: [[GroupCallGridTile]] = [[]]
        var n = 0
        for (i, p) in participants.enumerated() {
            let isLast = !isSubset && i == participants.count - 1
            let w = (p.videoAspectRatio ?? 1) * minHeight
            let isLastRow = rows.count == maxRows
            let rowMax = isLastRow && !isLast && roomForNext ? maxRowWidth - (button + margin) : maxRowWidth
            if width + w + (rows[rows.count - 1].isEmpty ? 0 : margin) <= rowMax {
                width += w + (rows[rows.count - 1].isEmpty ? 0 : margin)
                rows[rows.count - 1].append(.participant(p))
                n += 1
                if n == maxPerPage { return Page(rows: rows, numParticipants: n) }
            } else {
                if isLastRow { return Page(rows: rows, numParticipants: n) }
                rows.append([.participant(p)])
                n += 1
                width = w
            }
        }
        return Page(rows: rows, numParticipants: n)
    }

    /// `getGridParticipantsByPage`: pages in priority order, each re-sorted by demux id when
    /// that still fits.
    public static func pages(_ participants: [GroupCallRemoteParticipantInfo], maxRowWidth: Double, minHeight: Double, maxRows: Int,
                             maxPages: Int, currentPage: Int? = nil, maxPerPage: Int = maxParticipantsPerPage) -> [Page] {
        guard !participants.isEmpty else { return [] }
        var pages: [Page] = []
        var remaining = participants
        func total() -> Int { pages.reduce(0) { $0 + $1.numParticipants } }
        while !remaining.isEmpty {
            if currentPage == pages.count - 1 {
                pages.append(Page(rows: [remaining.map { .participant($0) }], numParticipants: remaining.count))
                return pages
            }
            let prev = !pages.isEmpty, next = pages.count + 1 < maxPages
            let priority = nextPage(remaining, maxRowWidth: maxRowWidth, minHeight: minHeight, maxRows: maxRows, maxPerPage: maxPerPage,
                                    roomForPrev: prev, roomForNext: next)
            var priorityOnPage: [GroupCallRemoteParticipantInfo] = priority.rows.flatMap { $0 }.compactMap { if case .participant(let p) = $0 { p } else { nil } }
            var hoping = priorityOnPage.sorted { $0.demuxId < $1.demuxId }
            var sorted = nextPage(hoping, maxRowWidth: maxRowWidth, minHeight: minHeight, maxRows: maxRows, maxPerPage: maxPerPage, roomForPrev: prev,
                                  roomForNext: next, isSubset: hoping.count < remaining.count)
            var page: Page?
            if sorted.numParticipants == priority.numParticipants {
                page = sorted
            } else {
                let toRemove = [1, 1, 1, 2, 5]
                var attempt = 0
                while !hoping.isEmpty && attempt < 5 {
                    let k = min(toRemove[min(attempt, toRemove.count - 1)], priorityOnPage.count)
                    let removed = Set(priorityOnPage.suffix(k).map(\.demuxId))
                    priorityOnPage.removeLast(k)
                    hoping = hoping.filter { !removed.contains($0.demuxId) }
                    sorted = nextPage(hoping, maxRowWidth: maxRowWidth, minHeight: minHeight, maxRows: maxRows, maxPerPage: maxPerPage, roomForPrev: prev,
                                      roomForNext: next)
                    if sorted.numParticipants == hoping.count {
                        page = sorted
                        break
                    }
                    attempt += 1
                }
                if page == nil { page = sorted }
            }
            guard var p = page else { break }
            if !pages.isEmpty { p.rows[0].insert(.pagination(next: false, count: total()), at: 0) }
            if p.numParticipants == 0 { break }
            remaining.removeFirst(p.numParticipants)
            pages.append(p)
            if pages.count == maxPages { break }
            if !remaining.isEmpty { pages[pages.count - 1].rows[pages[pages.count - 1].rows.count - 1].append(.pagination(next: true, count: remaining.count)) }
        }
        return pages
    }

    /// `getMaximumScaleForRows`
    static func maxScale(_ rows: [[GroupCallGridTile]], maxRowWidth: Double, minHeight: Double, maxGridHeight: Double) -> Double {
        guard let widest = rows.max(by: { rowWidth($0, minHeight) < rowWidth($1, minHeight) }) else { return 0 }
        let w = (maxRowWidth - Double(widest.count - 1) * margin) / rowWidth(widest, minHeight)
        let h = (maxGridHeight - Double(rows.count - 1) * margin) / (Double(rows.count) * minHeight)
        return min(w, h)
    }

    /// `arrangeParticipantsInGrid`: the row split with the largest scale.
    static func arrange(_ rows: [[GroupCallGridTile]], maxRowWidth: Double, minHeight: Double, maxRows: Int, maxGridHeight: Double)
        -> (rows: [[GroupCallGridTile]], scalar: Double) {
        var best = (rows: rows, scalar: maxScale(rows, maxRowWidth: maxRowWidth, minHeight: minHeight, maxGridHeight: maxGridHeight))
        let tiles = rows.flatMap { $0 }
        guard maxRows >= 1, !tiles.isEmpty else { return best }
        for rowCount in 1...maxRows {
            let per = Int((Double(tiles.count) / Double(rowCount)).rounded(.up))
            let chunked = stride(from: 0, to: tiles.count, by: per).map { Array(tiles[$0..<min($0 + per, tiles.count)]) }
            let s = maxScale(chunked, maxRowWidth: maxRowWidth, minHeight: minHeight, maxGridHeight: maxGridHeight)
            if s > best.scalar { best = (chunked, s) }
        }
        return best
    }

    /// The tiles of the current page, positioned in a `width`×`height` grid (rounded as
    /// upstream: tile height, each tile's width, the centring offsets).
    public static func place(_ page: Page?, width: Double, height: Double, minHeight: Double, maxRows: Int) -> (tiles: [Placed], tileHeight: Double) {
        guard let page else { return ([], 0) }
        let a = arrange(page.rows, maxRowWidth: width, minHeight: minHeight, maxRows: maxRows, maxGridHeight: height)
        let h = (a.scalar * minHeight).rounded()
        let rowsHeight = (h + margin) * Double(a.rows.count) - margin
        let top = max(0, ((height - rowsHeight) / 2).rounded())
        var out: [Placed] = []
        for (i, row) in a.rows.enumerated() {
            let y = top + Double(i) * (h + margin)
            let rowW = rowWidth(row, minHeight) * a.scalar + margin * Double(row.count - 1)
            let left = max(0, ((width - rowW) / 2).rounded())
            var x = 0.0
            for t in row {
                let w = (t.aspectRatio * h).rounded()
                out.append(Placed(tile: t, frame: CGRect(x: left + x, y: y, width: w, height: h)))
                x += w + margin
            }
        }
        return (out, h)
    }

    /// Presenter first, then the most recent speaker.
    public static func prioritySorted(_ ps: [GroupCallRemoteParticipantInfo], presenting: Set<UInt32>, speakerTime: [UInt32: Double])
        -> [GroupCallRemoteParticipantInfo] {
        ps.enumerated().sorted { a, b in
            let pa = presenting.contains(a.element.demuxId) ? 1 : 0, pb = presenting.contains(b.element.demuxId) ? 1 : 0
            if pa != pb { return pa > pb }
            let sa = speakerTime[a.element.demuxId] ?? -.infinity, sb = speakerTime[b.element.demuxId] ?? -.infinity
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }
}

public struct GroupCallRemoteParticipants: View {
    let participants: [GroupCallRemoteParticipantInfo]
    let callViewMode: CallViewMode
    let presenting: Set<UInt32>
    let speakerTime: [UInt32: Double]
    let audioLevels: [UInt32: Double]
    let isCallReconnecting: Bool
    let videoSource: (UInt32) -> (any CallVideoFrameSource)?
    let onClickRaisedHand: (() -> Void)?
    @State var pageIndex = 0
    @Environment(\.i18n) var i18n

    public init(participants: [GroupCallRemoteParticipantInfo], callViewMode: CallViewMode, presenting: Set<UInt32> = [], speakerTime: [UInt32: Double] = [:],
                audioLevels: [UInt32: Double] = [:], isCallReconnecting: Bool = false, videoSource: @escaping (UInt32) -> (any CallVideoFrameSource)? = { _ in nil },
                onClickRaisedHand: (() -> Void)? = nil) {
        self.participants = participants
        self.callViewMode = callViewMode
        self.presenting = presenting
        self.speakerTime = speakerTime
        self.audioLevels = audioLevels
        self.isCallReconnecting = isCallReconnecting
        self.videoSource = videoSource
        self.onClickRaisedHand = onClickRaisedHand
    }

    var isSpeakerView: Bool { callViewMode == .speaker || callViewMode == .presentation }
    var isPaginated: Bool { callViewMode == .paginated }
    var minHeight: Double { isPaginated ? GroupCallGridLayout.smallTilesMinHeight : GroupCallGridLayout.largeTilesMinHeight }

    func pages(_ size: CGSize, sorted: [GroupCallRemoteParticipantInfo]) -> [GroupCallGridLayout.Page] {
        let maxRows = Int(Double(size.height) / (minHeight + GroupCallGridLayout.margin))
        guard !sorted.isEmpty, maxRows > 0 else { return [] }
        if isSpeakerView { return [GroupCallGridLayout.Page(rows: [[.participant(sorted[0])]], numParticipants: 1)] }
        return GroupCallGridLayout.pages(sorted, maxRowWidth: Double(size.width), minHeight: minHeight, maxRows: maxRows,
                                         maxPages: isPaginated ? .max : 1, currentPage: pageIndex)
    }

    func tile(_ p: GroupCallRemoteParticipantInfo, _ frame: CGRect) -> some View {
        GroupCallRemoteParticipant(participant: p, width: frame.width, height: frame.height, inGrid: true, audioLevel: audioLevels[p.demuxId] ?? 0,
                                   remoteParticipantsCount: participants.count, isActiveSpeakerInSpeakerView: isSpeakerView,
                                   isCallReconnecting: isCallReconnecting, videoSource: videoSource(p.demuxId), onClickRaisedHand: onClickRaisedHand)
    }

    func paginationTile(next: Bool, count: Int, _ frame: CGRect) -> some View {
        let gray20 = AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20)
        return Button { pageIndex = next ? pageIndex + 1 : max(0, pageIndex - 1) } label: {
            HStack(spacing: 0) {
                if !next { SignalIcon("v3/chevron/chevron-left", size: 16, color: gray20, mask: true).frame(width: 16, height: 16) }
                CSSText("+\(count)", style: LegacyType.body1(), wrap: .nowrap, color: gray20)
                if next { SignalIcon("v3/chevron/chevron-right", size: 16, color: gray20, mask: true).frame(width: 16, height: 16) }
            }
            .frame(width: frame.width, height: frame.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgba: LegacyColor.gray78)))
        }
        .buttonStyle(UndimmedButtonStyle())
    }

    public var body: some View {
        let sorted = GroupCallGridLayout.prioritySorted(participants, presenting: presenting, speakerTime: speakerTime)
        GeometryReader { outer in
            // __grid--wrapper: 26px above, 16px below and either side; the overflow column
            // (60px + drag area from the top, 16px from the right) beside it.
            let gridSize = CGSize(width: max(0, outer.size.width - 32), height: max(0, outer.size.height - 42))
            let allPages = pages(gridSize, sorted: sorted)
            let inGrid = allPages.reduce(0) { $0 + $1.numParticipants }
            let overflow = isPaginated ? [] : Array(sorted.dropFirst(inGrid)).sorted { $0.demuxId < $1.demuxId }
            let gridWidth = overflow.isEmpty ? gridSize.width : max(0, gridSize.width - 16 - GroupCallGridLayout.overflowWidth)
            let finalPages = overflow.isEmpty ? allPages : pages(CGSize(width: gridWidth, height: gridSize.height), sorted: sorted)
            let page = finalPages.isEmpty ? nil : finalPages[min(pageIndex, finalPages.count - 1)]
            let maxRows = Int(Double(gridSize.height) / (minHeight + GroupCallGridLayout.margin))
            let placed = GroupCallGridLayout.place(page, width: Double(gridWidth), height: Double(gridSize.height), minHeight: minHeight, maxRows: maxRows)
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(placed.tiles.enumerated()), id: \.offset) { _, t in
                        Group {
                            switch t.tile {
                            case .participant(let p): tile(p, t.frame)
                            case .pagination(let next, let count): paginationTile(next: next, count: count, t.frame)
                            }
                        }
                        .offset(x: t.frame.minX, y: t.frame.minY)
                    }
                }
                .frame(width: gridWidth, height: gridSize.height, alignment: .topLeading)
                .padding(.top, 26).padding(.bottom, 16).padding(.horizontal, 16)
                if !overflow.isEmpty {
                    GroupCallOverflowArea(participants: overflow, audioLevels: audioLevels, remoteParticipantsCount: participants.count,
                                          isCallReconnecting: isCallReconnecting, videoSource: videoSource, onClickRaisedHand: onClickRaisedHand)
                        .frame(width: GroupCallGridLayout.overflowWidth)
                        .padding(.top, 60)
                        .padding(.trailing, 16)
                }
            }
        }
    }
}

/// `GroupCallOverflowArea`: the overflowed participants, 107px wide, scrolled from the
/// bottom, with up / down markers.
struct GroupCallOverflowArea: View {
    let participants: [GroupCallRemoteParticipantInfo]
    let audioLevels: [UInt32: Double]
    let remoteParticipantsCount: Int
    let isCallReconnecting: Bool
    let videoSource: (UInt32) -> (any CallVideoFrameSource)?
    let onClickRaisedHand: (() -> Void)?
    @Environment(\.axoStaticRendering) var staticRendering

    var body: some View {
        let tiles = VStack(spacing: 16) {
            ForEach(participants) { p in
                GroupCallRemoteParticipant(participant: p, width: GroupCallGridLayout.overflowWidth,
                                           height: (GroupCallGridLayout.overflowWidth / (p.videoAspectRatio ?? 1)).rounded(.down), isInOverflow: true,
                                           audioLevel: audioLevels[p.demuxId] ?? 0, remoteParticipantsCount: remoteParticipantsCount,
                                           isCallReconnecting: isCallReconnecting, videoSource: videoSource(p.demuxId), onClickRaisedHand: onClickRaisedHand)
            }
        }
        .padding(.bottom, 16)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if staticRendering {
                // (ImageRenderer draws no ScrollView: the column as scrolled to its end.)
                Color.clear.overlay(alignment: .bottom) { tiles.fixedSize(horizontal: false, vertical: true) }.clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) { tiles }
                    .defaultScrollAnchor(.bottom)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
