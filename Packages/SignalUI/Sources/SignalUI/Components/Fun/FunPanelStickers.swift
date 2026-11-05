// Port of ts/components/fun/panels/FunPanelStickers.dom.tsx and FunStickerPicker.dom.tsx:
// the sticker panel. Search, then sections (Featured time stickers, Favorites, Recently Used,
// each installed pack) of 4 × 80px cells holding the sticker at its natural size within the
// cell, and a horizontally scrolling sub-nav (Favorites, Recents, each pack's 26px cover;
// 40px fades at both ends) with an optional "add sticker pack" button.
//
// Not ported yet: the sticker lightbox (long press) and the time stickers.

import SignalI18n
import SwiftUI

public struct FunStickerItem: Hashable, Sendable {
    public var id: Int
    public var packId: String
    public var image: RGBAImage?
    public var emoji: String?
    public init(id: Int, packId: String, image: RGBAImage?, emoji: String? = nil) {
        self.id = id
        self.packId = packId
        self.image = image
        self.emoji = emoji
    }
}

public struct FunStickerPack: Hashable, Sendable {
    public var id: String
    public var title: String
    public var cover: RGBAImage?
    public var stickers: [FunStickerItem]
    public init(id: String, title: String, cover: RGBAImage?, stickers: [FunStickerItem]) {
        self.id = id
        self.title = title
        self.cover = cover
        self.stickers = stickers
    }
}

public enum FunStickersSection: Hashable, Sendable {
    case searchResults, favorites, recents, featured
    case pack(String)
}

public struct FunPanelStickers: View {
    let packs: [FunStickerPack]
    let favorites: [FunStickerItem]
    let recents: [FunStickerItem]
    let isFavoriteStickersEnabled: Bool
    let showAddStickerPackButton: Bool
    let onSelectSticker: (FunStickerItem) -> Void
    let onAddStickerPack: () -> Void
    @State private var searchInput = ""
    @State private var selected: FunStickersSection?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    static let columns = 4, cell: CGFloat = 80

    public init(packs: [FunStickerPack], favorites: [FunStickerItem], recents: [FunStickerItem], isFavoriteStickersEnabled: Bool = true,
                showAddStickerPackButton: Bool = false, onSelectSticker: @escaping (FunStickerItem) -> Void = { _ in },
                onAddStickerPack: @escaping () -> Void = {}) {
        self.packs = packs
        self.favorites = favorites
        self.recents = recents
        self.isFavoriteStickersEnabled = isFavoriteStickersEnabled
        self.showAddStickerPackButton = showAddStickerPackButton
        self.onSelectSticker = onSelectSticker
        self.onAddStickerPack = onAddStickerPack
        let first: FunStickersSection? = isFavoriteStickersEnabled && !favorites.isEmpty ? .favorites
            : !recents.isEmpty ? .recents : packs.first.map { .pack($0.id) }
        _selected = State(initialValue: first)
    }

    var sections: [(id: FunStickersSection, title: String, stickers: [FunStickerItem])] {
        let q = searchInput.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let data = EmojiData.shared, lower = q.lowercased()
            let hits = packs.flatMap(\.stickers).filter { s in s.emoji.map { (data.shortName($0) ?? "").contains(lower) } ?? false }
            return [(.searchResults, i18n("icu:FunPanelStickers__SectionTitle--SearchResults"), hits)]
        }
        var out: [(FunStickersSection, String, [FunStickerItem])] = []
        if isFavoriteStickersEnabled && !favorites.isEmpty { out.append((.favorites, i18n("icu:FunPanelStickers__SectionTitle--Favorites"), favorites)) }
        if !recents.isEmpty { out.append((.recents, i18n("icu:FunPanelStickers__SectionTitle--Recents"), recents)) }
        for p in packs { out.append((.pack(p.id), p.title, p.stickers)) }
        return out
    }

    public var body: some View {
        let sections = self.sections
        FunPanel {
            AxoSearchField.Root(value: $searchInput) {
                AxoSearchField.Icon()
                AxoSearchField.Input(placeholder: i18n("icu:FunPanelStickers__SearchPlaceholder"), autoFocus: true)
                AxoSearchField.Clear()
            }
            .accessibilityLabel(i18n("icu:FunPanelStickers__SearchLabel"))
        } body: {
            if sections.allSatisfy({ $0.stickers.isEmpty }) && !searchInput.isEmpty {
                FunResultsHeader(runs: [CSSTextRun(i18n("icu:FunPanelStickers__SearchResults__EmptyHeading") + " "), Emojify.run("🙁")])
            } else {
                ScrollViewReader { proxy in
                    FunScroller {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(sections, id: \.id) { s in sectionView(s) }
                        }
                    }
                    .onChange(of: selected) { if !staticRendering, let selected { proxy.scrollTo(selected, anchor: .top) } }
                }
            }
        } footer: {
            if searchInput.isEmpty { subNav }
        }
    }

    func sectionView(_ s: (id: FunStickersSection, title: String, stickers: [FunStickerItem])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FunGridHeader(title: s.title) { EmptyView() }
            let rows = stride(from: 0, to: s.stickers.count, by: Self.columns).map { Array(s.stickers[$0..<min($0 + Self.columns, s.stickers.count)]) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(Array(rows[r].enumerated()), id: \.offset) { _, sticker in
                            FunItemButton(label: sticker.emoji ?? "") { onSelectSticker(sticker) } content: {
                                if let image = sticker.image { FittedSticker(image: image, box: Self.cell - 4) }
                            }
                            .frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
        }
        .id(s.id)
    }

    var subNav: some View {
        var items: [(FunStickersSection, String, AnyView)] = []
        if isFavoriteStickersEnabled && !favorites.isEmpty {
            items.append((.favorites, i18n("icu:FunPanelStickers__SubNavCategoryLabel--Favorites"),
                          AnyView(SignalIcon("v3/star/star", size: 20, color: .labelSecondary, mask: true))))
        }
        if !recents.isEmpty {
            items.append((.recents, i18n("icu:FunPanelStickers__SubNavCategoryLabel--Recents"),
                          AnyView(SignalIcon("v3/recent/recent", size: 20, color: .labelSecondary, mask: true))))
        }
        for p in packs {
            let isSelected = selected == .pack(p.id)
            items.append((.pack(p.id), p.title, AnyView(Group {
                if let cover = p.cover {
                    // FunSubNav__Image: 26px, (10 − 3)px corners, 90% when selected
                    PixelImage(cover, fit: .fill).frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 7))
                        .scaleEffect(isSelected ? 0.9 : 1)
                }
            })))
        }
        return HStack(spacing: 0) {
            FunSubNavScroller {
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        FunSubNavContentButton(label: items[i].1, isSelected: items[i].0 == selected) { selected = items[i].0 } content: { items[i].2 }
                            .padding(.vertical, 1)
                            .padding(.leading, i == 0 ? 6 : 1)
                            .padding(.trailing, i == items.count - 1 ? 6 : 1)
                    }
                }
                .padding(.vertical, 6)
            }
            if showAddStickerPackButton {
                FunSubNavContentButton(label: i18n("icu:FunPanelStickers__SubNavButton--AddStickerPack"), isSelected: false, action: onAddStickerPack) {
                    SignalIcon("v3/plus/plus-circle", size: 20, color: .labelSecondary, mask: true)
                }
                .padding(6)
            }
        }
    }
}

/// A sticker at its natural size, scaled down (aspect kept) to fit `box`.
struct FittedSticker: View {
    let image: RGBAImage
    let box: CGFloat
    var body: some View {
        let w = CGFloat(image.width) / image.scale, h = CGFloat(image.height) / image.scale
        let s = min(1, box / w, box / h)
        PixelImage(image, fit: .fill).frame(width: w * s, height: h * s).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A 32px sub-nav button around arbitrary content (an icon or a pack cover).
struct FunSubNavContentButton<Content: View>: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    let content: Content
    @State private var hovered = false
    init(label: String, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }
    var body: some View {
        SwiftUI.Button(action: action) {
            content
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? AxoColor.fillPrimaryPressed : hovered ? AxoColor.fillPrimary : AxoColor(RGBA(0, 0, 0, 0))))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// `FunSubNavScroller`: horizontal scrolling, with 40px material-dialog fades at the edges.
struct FunSubNavScroller<Content: View>: View {
    let content: Content
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.colorScheme) var scheme
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let bg = AxoColor.materialDialog.value(for: scheme)
        Group {
            if staticRendering {
                Color.clear.frame(height: 46).overlay(alignment: .leading) { content.fixedSize() }.clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) { content }
            }
        }
        .overlay(alignment: .leading) { fade(bg, from: .leading) }
        .overlay(alignment: .trailing) { fade(bg, from: .trailing) }
        .frame(maxWidth: .infinity)
    }
    func fade(_ c: RGBA, from edge: UnitPoint) -> some View {
        // linear-gradient(to right, mask 20%, transparent)
        LinearGradient(stops: [.init(color: c.color, location: 0), .init(color: c.color, location: 0.2), .init(color: c.color.opacity(0), location: 1)],
                       startPoint: edge, endPoint: edge == .leading ? .trailing : .leading)
            .frame(width: 40)
            .allowsHitTesting(false)
    }
}

/// `FunStickerPicker`: the sticker panel in a Fun popover.
public struct FunStickerPicker: View {
    let panel: FunPanelStickers
    public init(panel: FunPanelStickers) { self.panel = panel }
    public var body: some View { FunPopoverDialog { panel } }
}
