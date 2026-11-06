// Port of ts/components/fun/panels/FunPanelGifs.dom.tsx (+ FunWaterfall, FunResults): the GIF
// panel. Search (500 ms debounce, at most 50 bytes / 50 graphemes), a sub-nav of Recents and
// eight categories (Trending, then searches for celebrate, love, thumbs-up, …), and results
// in a two-lane waterfall of 160px items (2px margins) placed like @tanstack/virtual's
// lanes: each item goes to the lane that ends highest. Pages are 10 GIFs, then 30 as the
// end comes within 8 items of view. A GIPHY attribution pill shows until the first scroll.
//
// Items load their preview rendition's player when they come into view (lazy lanes) and
// release it when they leave; the data source (the app: SignalCore's GiphyClient through the
// content proxy, frames from the media service) provides both pages and players.
//
// Not ported yet: the long-press lightbox and the arrow-key waterfall navigation.

import SignalI18n
import SwiftUI

public struct FunGifMedia: Hashable, Sendable {
    public var url: URL
    public var width: Int
    public var height: Int
    public init(url: URL, width: Int, height: Int) {
        self.url = url
        self.width = width
        self.height = height
    }
}

/// `GifType`
public struct FunGifItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var previewMedia: FunGifMedia
    public var attachmentMedia: FunGifMedia
    public init(id: String, title: String, description: String, previewMedia: FunGifMedia, attachmentMedia: FunGifMedia) {
        self.id = id
        self.title = title
        self.description = description
        self.previewMedia = previewMedia
        self.attachmentMedia = attachmentMedia
    }
}

/// `PaginatedGifResults`
public struct FunGifsPage: Sendable, Equatable {
    public var next: Int?
    public var gifs: [FunGifItem]
    public init(next: Int?, gifs: [FunGifItem]) {
        self.next = next
        self.gifs = gifs
    }
}

/// `FunGifsSection` (FunSectionCommon + FunGifsCategory)
public enum FunGifsSection: String, Hashable, Sendable, CaseIterable {
    case searchResults, recents, trending, celebrate, love, thumbsUp, surprised, excited, sad, angry

    static let categories: [FunGifsSection] = [.trending, .celebrate, .love, .thumbsUp, .surprised, .excited, .sad, .angry]

    /// The Giphy search a category stands for.
    var searchTerm: String? {
        switch self {
        case .celebrate: "celebrate"
        case .love: "love"
        case .thumbsUp: "thumbs-up"
        case .surprised: "surprised"
        case .excited: "excited"
        case .sad: "sad"
        case .angry: "angry"
        default: nil
        }
    }

    var labelKey: String {
        switch self {
        case .recents: "Recents"
        case .trending: "Trending"
        case .celebrate: "Celebrate"
        case .love: "Love"
        case .thumbsUp: "ThumbsUp"
        case .surprised: "Surprised"
        case .excited: "Excited"
        case .sad: "Sad"
        case .angry: "Angry"
        case .searchResults: "SearchResults"
        }
    }

    var icon: String {
        switch self {
        case .recents: "v3/recent/recent"
        case .trending: "v3/trending/trending"
        case .celebrate: "v3/emoji/emoji-celebrate"
        case .love: "v3/heart/heart"
        case .thumbsUp: "v3/emoji/emoji-thumbs_up"
        case .surprised: "v3/emoji/emoji-surprised"
        case .excited: "v3/emoji/emoji-excited"
        case .sad: "v3/emoji/emoji-sad"
        case .angry: "v3/emoji/emoji-angry"
        case .searchResults: "v3/search/search"
        }
    }
}

/// Where the panel gets GIFs and their players.
public struct FunGifsDataSource {
    public var trending: @MainActor (_ limit: Int, _ offset: Int?) async throws -> FunGifsPage
    public var search: @MainActor (_ query: String, _ limit: Int, _ offset: Int?) async throws -> FunGifsPage
    /// A loaded player for a GIF's preview rendition (nil if it could not be fetched or opened).
    public var previewPlayer: @MainActor (FunGifItem) async -> VideoPlaybackEngine?

    public init(trending: @escaping @MainActor (Int, Int?) async throws -> FunGifsPage,
                search: @escaping @MainActor (String, Int, Int?) async throws -> FunGifsPage,
                previewPlayer: @escaping @MainActor (FunGifItem) async -> VideoPlaybackEngine?) {
        self.trending = trending
        self.search = search
        self.previewPlayer = previewPlayer
    }
}

/// `useInfiniteQuery` over GIF pages for one (section, search) query.
@MainActor
@Observable
public final class FunGifsQuery {
    public struct Key: Hashable, Sendable {
        public var section: FunGifsSection
        public var searchQuery: String
    }
    public private(set) var key: Key
    public internal(set) var pages: [FunGifsPage] = []
    public private(set) var pending = false
    public private(set) var rejected = false
    @ObservationIgnored let source: FunGifsDataSource
    @ObservationIgnored var generation = 0

    init(key: Key, source: FunGifsDataSource) {
        self.key = key
        self.source = source
    }

    var hasNextPage: Bool { pages.isEmpty ? !rejected : pages.last?.next != nil }

    func load(_ k: Key) async {
        generation += 1
        key = k
        pages = []
        rejected = false
        pending = false
        await fetchNextPage()
    }

    func revalidate() async { await load(key) }

    func fetchNextPage() async {
        guard !pending, hasNextPage else { return }
        let gen = generation, k = key
        let cursor = pages.last?.next
        let limit = cursor != nil ? 30 : 10
        pending = true
        defer { if gen == generation { pending = false } }
        do {
            let page: FunGifsPage
            if !k.searchQuery.isEmpty {
                page = try await source.search(k.searchQuery, limit, cursor)
            } else if k.section == .recents || k.section == .searchResults {
                page = FunGifsPage(next: nil, gifs: [])
            } else if k.section == .trending {
                page = try await source.trending(limit, cursor)
            } else {
                page = try await source.search(k.section.searchTerm ?? "", limit, cursor)
            }
            guard gen == generation else { return }
            pages.append(page)
        } catch {
            guard gen == generation else { return }
            rejected = true
        }
    }
}

/// `FunGifSelection`
public struct FunGifSelection: Sendable, Hashable {
    public var gif: FunGifItem
}

public struct FunPanelGifs: View {
    static let columns = 2, itemWidth: CGFloat = 160, itemMargin: CGFloat = 2
    static var itemTotalWidth: CGFloat { itemWidth + 2 * itemMargin }
    static let maxQuery = 50

    let recentGifs: [FunGifItem]
    let source: FunGifsDataSource
    let onSelectGif: (FunGifSelection) -> Void
    let onRemoveRecentGif: (String) -> Void
    let onClose: () -> Void
    @Binding var storedSearchInput: String
    @State private var searchInput: String
    @State private var selectedSection: FunGifsSection
    @State private var query: FunGifsQuery
    @State private var didScroll = false
    @Environment(\.i18n) var i18n

    public init(recentGifs: [FunGifItem], source: FunGifsDataSource, storedSearchInput: Binding<String> = .constant(""),
                onSelectGif: @escaping (FunGifSelection) -> Void = { _ in }, onRemoveRecentGif: @escaping (String) -> Void = { _ in },
                onClose: @escaping () -> Void = {}, prefetched: FunGifsPage? = nil) {
        self.recentGifs = recentGifs
        self.source = source
        self.onSelectGif = onSelectGif
        self.onRemoveRecentGif = onRemoveRecentGif
        self.onClose = onClose
        _storedSearchInput = storedSearchInput
        let input = storedSearchInput.wrappedValue
        let section = Self.selectedSection(hasSearchQuery: !input.trimmingCharacters(in: .whitespaces).isEmpty, hasRecentGifs: !recentGifs.isEmpty)
        _searchInput = State(initialValue: input)
        _selectedSection = State(initialValue: section)
        let q = FunGifsQuery(key: .init(section: section, searchQuery: input.trimmingCharacters(in: .whitespaces)), source: source)
        // A first page already at hand (previews, snapshots).
        if let prefetched { q.pages = [prefetched] }
        _query = State(initialValue: q)
    }

    /// `getSelectedSection`
    static func selectedSection(hasSearchQuery: Bool, hasRecentGifs: Bool) -> FunGifsSection {
        hasSearchQuery ? .searchResults : hasRecentGifs ? .recents : .trending
    }

    /// FunSearch's maxBytes / maxGraphemes: whole graphemes while both stay within 50.
    static func limited(_ s: String) -> String {
        var out = "", bytes = 0, count = 0
        for g in s {
            let n = String(g).utf8.count
            if bytes + n > maxQuery || count + 1 > maxQuery { break }
            out.append(g)
            bytes += n
            count += 1
        }
        return out
    }

    var searchQuery: String { searchInput.trimmingCharacters(in: .whitespaces) }
    var debounceKey: FunGifsQuery.Key { .init(section: selectedSection, searchQuery: searchQuery) }

    var items: [FunGifItem] { query.key.section == .recents && query.key.searchQuery.isEmpty ? recentGifs : query.pages.flatMap(\.gifs) }

    /// While a search is pending the sub-nav keeps the section of the shown results.
    var visibleSelectedSection: FunGifsSection { selectedSection == .searchResults ? query.key.section : selectedSection }

    public var body: some View {
        let items = self.items
        FunPanel {
            AxoSearchField.Root(value: $searchInput) {
                AxoSearchField.Icon()
                AxoSearchField.Input(placeholder: i18n("icu:FunPanelGifs__SearchPlaceholder"), autoFocus: true)
                AxoSearchField.Clear()
            }
            .accessibilityLabel(i18n("icu:FunPanelGifs__SearchLabel"))
        } body: {
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    FunScroller(onScrolledFromTop: { if !didScroll { withAnimation { didScroll = true } } }) {
                        Color.clear.frame(height: 0).id("top")
                        if items.isEmpty {
                            results.frame(width: FunMetrics.dialogWidth - 13, height: FunMetrics.panelHeight - 104)
                        } else {
                            waterfall(items)
                        }
                    }
                    .onChange(of: query.key) { proxy.scrollTo("top", anchor: .top) }
                }
                if !didScroll { attribution.transition(.opacity) }
            }
        } footer: {
            if visibleSelectedSection != .searchResults {
                FunSubNavListBox(items: navItems, selected: visibleSelectedSection) { id in
                    searchInput = ""
                    selectedSection = id
                }
                .accessibilityLabel(i18n("icu:FunPanelGifs__SubNavLabel"))
            }
        }
        .onChange(of: searchInput) { _, v in
            let limited = Self.limited(v)
            if limited != v { searchInput = limited; return }
            // handleSearchInputChange
            selectedSection = Self.selectedSection(hasSearchQuery: !searchQuery.isEmpty, hasRecentGifs: !recentGifs.isEmpty)
            storedSearchInput = v
        }
        .task(id: debounceKey) {
            let k = debounceKey
            if k == query.key && (!query.pages.isEmpty || query.pending || query.rejected) { return }
            // Searches are deferred by 500 ms; sections load at once.
            if !k.searchQuery.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            await query.load(k)
        }
    }

    var navItems: [FunSubNavListBox<FunGifsSection>.Item] {
        ((recentGifs.isEmpty ? [] : [FunGifsSection.recents]) + FunGifsSection.categories)
            .map { .init(id: $0, label: i18n("icu:FunPanelGifs__SubNavCategoryLabel--" + $0.labelKey), icon: $0.icon) }
    }

    @ViewBuilder var results: some View {
        VStack(spacing: 12) {
            if query.pending {
                SpinnerV2(size: 36, strokeWidth: 2)
                    .accessibilityLabel(i18n("icu:FunPanelGifs__SearchResults__LoadingLabel"))
            } else if query.rejected {
                FunResultsHeader(runs: [CSSTextRun(i18n("icu:FunPanelGifs__SearchResults__ErrorHeading"))]).fixedSize(horizontal: false, vertical: true)
                SwiftUI.Button { Task { await query.revalidate() } } label: {
                    CSSText(i18n("icu:FunPanelGifs__SearchResults__ErrorRetryButton"), style: LegacyType.subtitle(), wrap: .nowrap, color: .labelPrimary)
                        .padding(.vertical, 6).padding(.horizontal, 28)
                        .background(Capsule().fill(AxoColor.fillPrimary))
                }
                .buttonStyle(.plain)
            } else {
                FunResultsHeader(runs: [CSSTextRun(i18n("icu:FunPanelGifs__SearchResults__EmptyHeading") + " "), Emojify.run("🙁")])
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
    }

    /// Lane of every item and its height (tanstack virtual `lanes`: the lane whose last item
    /// ends first, ties to the earlier item; the first items fill lanes in order).
    static func lanes(_ items: [FunGifItem]) -> [[(index: Int, height: CGFloat)]] {
        var out = Array(repeating: [(index: Int, height: CGFloat)](), count: columns)
        var end = [CGFloat](repeating: 0, count: columns), last = [Int](repeating: -1, count: columns)
        for (i, g) in items.enumerated() {
            let aspect = CGFloat(max(1, g.previewMedia.width)) / CGFloat(max(1, g.previewMedia.height))
            let h = itemWidth / aspect + 2 * itemMargin
            let lane: Int
            if last.contains(-1) {
                lane = i % columns
            } else {
                lane = (0 ..< columns).min { end[$0] != end[$1] ? end[$0] < end[$1] : last[$0] < last[$1] }!
            }
            out[lane].append((i, h))
            end[lane] += h
            last[lane] = i
        }
        return out
    }

    func waterfall(_ items: [FunGifItem]) -> some View {
        let lanes = Self.lanes(items)
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0 ..< Self.columns, id: \.self) { l in
                LazyVStack(spacing: 0) {
                    ForEach(lanes[l], id: \.index) { entry in
                        FunGifsItem(gif: items[entry.index], height: entry.height, source: source, onRemoveRecentGif: onRemoveRecentGif) {
                            onSelectGif(FunGifSelection(gif: items[entry.index]))
                            onClose()
                        }
                        .id(items[entry.index].id)
                        .onAppear {
                            // Near the end of the list: fetch more.
                            if entry.index + 4 * Self.columns >= items.count - 1 && query.hasNextPage && !query.pending {
                                Task { await query.fetchNextPage() }
                            }
                        }
                    }
                }
                .frame(width: Self.itemTotalWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The GIPHY attribution: 4px from the bottom, a black/70 pill (18px × 6px padding) around
    /// the image, which lays out at 140 × 15.5 (not its 160.25 × 17.75 attributes).
    @ViewBuilder var attribution: some View {
        if let img = BundledImage.named("giphy-attribution") {
            PixelImage(img, fit: .fill)
                .frame(width: 140, height: 15.5)
                .padding(.horizontal, 18).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .padding(.bottom, 4)
                .allowsHitTesting(false)
                .accessibilityLabel(i18n("icu:FunPanelGifs__GiphyAttribution__AccessibilityLabel"))
        }
    }
}

/// One waterfall item: the preview's player while in view.
struct FunGifsItem: View {
    let gif: FunGifItem
    let height: CGFloat
    let source: FunGifsDataSource
    let onRemoveRecentGif: (String) -> Void
    let onClick: () -> Void
    @State private var player: VideoPlaybackEngine?

    var body: some View {
        FunItemButton(label: gif.title, action: onClick) {
            if let player {
                FunGif(frame: nil, width: CGFloat(gif.previewMedia.width), height: CGFloat(gif.previewMedia.height), accessibilityLabel: gif.description, player: player)
            }
        }
        .frame(width: FunPanelGifs.itemTotalWidth, height: height)
        .task(id: gif.id) {
            // isGiphyCdnUrl, else the recent GIF is dropped.
            guard ["media0.giphy.com", "media1.giphy.com", "media2.giphy.com", "media3.giphy.com", "media4.giphy.com"].contains(gif.previewMedia.url.host ?? ""),
                  gif.previewMedia.url.scheme == "https" else {
                onRemoveRecentGif(gif.id)
                return
            }
            if player == nil { player = await source.previewPlayer(gif) }
        }
        .onDisappear {
            let p = player
            player = nil
            Task { await p?.unload() }
        }
    }
}
