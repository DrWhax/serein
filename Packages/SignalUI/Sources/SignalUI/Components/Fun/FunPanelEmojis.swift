// Port of ts/components/fun/panels/FunPanelEmojis.dom.tsx and FunEmojiPicker.dom.tsx: the
// emoji panel. The search field (autofocused), an optional customize-reactions button, then
// sections (This Message, Recently Used, the eight categories; search results while
// searching) of 8 × 40px cells with 32px emoji, 28px headers and 20px between sections, and
// the category sub-nav, whose selection follows the scroll position.
//
// Skin tones: an emoji that has them uses the default tone (`skinTone`); with none chosen yet,
// picking one first asks for the default (upstream's FunEmojiSkinTonePopover; here a card over
// the panel), then picks the emoji in that tone. The header "more" button and the context menu
// change the default. A caller may take this over with `onOpenSkinTonePicker`.
//
// Not ported yet: Fuse.js fuzzy search (a short-name match stands in).

import SignalI18n
import SwiftUI

public enum FunEmojisSection: Hashable, Sendable {
    case searchResults, thisMessage, recents
    case category(EmojiCategory)
}

public struct FunPanelEmojis: View {
    let recentEmojis: [String]
    let messageEmojis: [String]
    let skinTone: EmojiSkinTone?
    let showCustomizePreferredReactionsButton: Bool
    let onSelectEmoji: (String) -> Void
    let onOpenCustomizePreferredReactionsModal: () -> Void
    let onOpenSkinTonePicker: ((String?) -> Void)?
    let onSelectSkinTone: (EmojiSkinTone) -> Void
    @State private var searchInput: String
    @State private var selected: FunEmojisSection
    /// The tone chosen in this panel (before the caller's `skinTone` reflects it).
    @State private var chosenTone: EmojiSkinTone?
    /// The skin-tone chooser on screen: for this emoji (nil: the default only).
    @State private var choosingTone: ToneChoice?

    struct ToneChoice: Equatable { var parent: String? }
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    static let columns = 8, cell: CGFloat = 40, sectionGap: CGFloat = 20, headerSize: CGFloat = 28

    /// The order sections appear in (`FunEmojisSectionOrder`).
    static let categoryOrder: [EmojiCategory] = [.smileysAndPeople, .animalsAndNature, .foodAndDrink, .activities, .travelAndPlaces,
                                                 .objects, .symbols, .flags]

    public init(recentEmojis: [String], messageEmojis: [String] = [], skinTone: EmojiSkinTone? = nil, searchInput: String = "",
                showCustomizePreferredReactionsButton: Bool = false, onSelectEmoji: @escaping (String) -> Void = { _ in },
                onOpenCustomizePreferredReactionsModal: @escaping () -> Void = {}, onOpenSkinTonePicker: ((String?) -> Void)? = nil,
                onSelectSkinTone: @escaping (EmojiSkinTone) -> Void = { _ in }) {
        self.recentEmojis = recentEmojis
        self.messageEmojis = messageEmojis
        self.skinTone = skinTone
        self.showCustomizePreferredReactionsButton = showCustomizePreferredReactionsButton
        self.onSelectEmoji = onSelectEmoji
        self.onOpenCustomizePreferredReactionsModal = onOpenCustomizePreferredReactionsModal
        self.onOpenSkinTonePicker = onOpenSkinTonePicker
        self.onSelectSkinTone = onSelectSkinTone
        _searchInput = State(initialValue: searchInput)
        let query = searchInput.trimmingCharacters(in: .whitespaces)
        _selected = State(initialValue: !query.isEmpty ? .searchResults : !recentEmojis.isEmpty ? .recents : .category(.smileysAndPeople))
    }

    var query: String { searchInput.trimmingCharacters(in: .whitespaces) }

    /// The default skin tone: the caller's, or the one chosen here; nil until one is chosen.
    var tone: EmojiSkinTone? { skinTone ?? chosenTone }

    func chooseTone(for parent: String?) {
        if let onOpenSkinTonePicker { onOpenSkinTonePicker(parent) } else { choosingTone = ToneChoice(parent: parent) }
    }

    var sections: [(id: FunEmojisSection, emojis: [String])] {
        let data = EmojiData.shared, tone = self.tone ?? .none
        if !query.isEmpty {
            let q = query.lowercased()
            let hits = Self.categoryOrder.flatMap { data.parents(in: $0) }.filter { (data.shortName($0) ?? "").contains(q) }
            return [(.searchResults, hits.map { data.variant($0, skinTone: tone) })]
        }
        var out: [(FunEmojisSection, [String])] = []
        if !messageEmojis.isEmpty { out.append((.thisMessage, messageEmojis)) }
        if !recentEmojis.isEmpty { out.append((.recents, recentEmojis.map { data.variant($0, skinTone: tone) })) }
        for c in Self.categoryOrder { out.append((.category(c), data.parents(in: c).map { data.variant($0, skinTone: tone) })) }
        return out
    }

    func title(_ s: FunEmojisSection) -> String {
        switch s {
        case .searchResults: i18n("icu:FunPanelEmojis__SectionTitle--SearchResults")
        case .recents: i18n("icu:FunPanelEmojis__SectionTitle--Recents")
        case .thisMessage: i18n("icu:FunPanelEmojis__SectionTitle--ThisMessage")
        case .category(let c): i18n("icu:FunPanelEmojis__SectionTitle--" + Self.key(c))
        }
    }

    static func key(_ c: EmojiCategory) -> String {
        switch c {
        case .smileysAndPeople: "SmileysAndPeople"
        case .animalsAndNature: "AnimalsAndNature"
        case .foodAndDrink: "FoodAndDrink"
        case .travelAndPlaces: "TravelAndPlaces"
        case .activities: "Activities"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    static func icon(_ c: EmojiCategory) -> String {
        switch c {
        case .smileysAndPeople: "v3/emoji/emoji"
        case .animalsAndNature: "v3/emoji/emoji-animal"
        case .foodAndDrink: "v3/emoji/emoji-food"
        case .activities: "v3/emoji/emoji-activity"
        case .travelAndPlaces: "v3/emoji/emoji-travel"
        case .objects: "v3/emoji/emoji-object"
        case .symbols: "v3/emoji/emoji-symbol"
        case .flags: "v3/emoji/emoji-flag"
        }
    }

    var navItems: [FunSubNavListBox<FunEmojisSection>.Item] {
        var items: [FunSubNavListBox<FunEmojisSection>.Item] = []
        if !recentEmojis.isEmpty {
            items.append(.init(id: .recents, label: i18n("icu:FunPanelEmojis__SubNavCategoryLabel--Recents"), icon: "v3/recent/recent"))
        }
        for c in Self.categoryOrder {
            items.append(.init(id: .category(c), label: i18n("icu:FunPanelEmojis__SubNavCategoryLabel--" + Self.key(c)), icon: Self.icon(c)))
        }
        return items
    }

    public var body: some View {
        let sections = self.sections
        FunPanel {
            AxoSearchField.Root(value: $searchInput) {
                AxoSearchField.Icon()
                AxoSearchField.Input(placeholder: i18n("icu:FunPanelEmojis__SearchPlaceholder"), autoFocus: true)
                AxoSearchField.Clear()
            }
            .accessibilityLabel(i18n("icu:FunPanelEmojis__SearchLabel"))
            if showCustomizePreferredReactionsButton {
                SwiftUI.Button(action: onOpenCustomizePreferredReactionsModal) {
                    SignalIcon("v3/settings/settings-compact", size: 20, color: .labelPrimary, mask: true)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:FunPanelEmojis__CustomizeReactionsButtonLabel"))
            }
        } body: {
            if sections.allSatisfy({ $0.emojis.isEmpty }) {
                FunResultsHeader(runs: [CSSTextRun(i18n("icu:FunPanelEmojis__SearchResults__EmptyHeading") + " "), Emojify.run("🙁")])
            } else {
                ScrollViewReader { proxy in
                    FunScroller {
                        VStack(alignment: .leading, spacing: Self.sectionGap) {
                            ForEach(sections, id: \.id) { section in sectionView(section) }
                        }
                    }
                    .onChange(of: selected) { if !staticRendering { proxy.scrollTo(selected, anchor: .top) } }
                }
            }
        } footer: {
            if searchInput.isEmpty {
                FunSubNavListBox(items: navItems, selected: selected) { id in
                    selected = id
                    searchInput = ""
                }
            }
        }
        .overlay { if let choice = choosingTone { toneChooser(choice) } }
    }

    /// "Choose default skin tone", over the panel; outside it cancels.
    func toneChooser(_ choice: ToneChoice) -> some View {
        ZStack {
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture { choosingTone = nil }
            VStack(spacing: 8) {
                CSSText(i18n("icu:FunPanelEmojis__SkinTonePicker__ChooseDefaultLabel"), style: LegacyType.body1(), wrap: .nowrap,
                        alignment: .center, color: .labelPrimary)
                FunSkinTonesList(emoji: choice.parent ?? "✋", skinTone: tone) { picked in
                    chosenTone = picked
                    choosingTone = nil
                    onSelectSkinTone(picked)
                    if let parent = choice.parent { onSelectEmoji(EmojiData.shared.variant(parent, skinTone: picked)) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(AxoColor.materialDialog))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AxoColor.borderPrimary))
        }
    }

    func sectionView(_ section: (id: FunEmojisSection, emojis: [String])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FunGridHeader(title: title(section.id)) {
                if section.id == .category(.smileysAndPeople) {
                    SwiftUI.Button { chooseTone(for: nil) } label: {
                        SignalIcon("v3/more/more-circle-bold", size: 16, color: .labelSecondary, mask: true)
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:FunPanelEmojis__ChangeSkinToneButtonLabel"))
                }
            }
            let rows = stride(from: 0, to: section.emojis.count, by: Self.columns).map { Array(section.emojis[$0..<min($0 + Self.columns, section.emojis.count)]) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(rows[r], id: \.self) { emoji in cell(emoji).frame(width: Self.cell, height: Self.cell) }
                    }
                }
            }
        }
        .id(section.id)
    }

    func cell(_ emoji: String) -> some View {
        let data = EmojiData.shared
        let parent = data.parent(of: emoji)
        return FunItemButton(label: data.shortName(emoji).map { ":\($0):" } ?? emoji) {
            if data.hasSkinTones(parent) && tone == nil {
                chooseTone(for: parent)
            } else {
                onSelectEmoji(emoji)
            }
        } content: {
            FunStaticEmoji(emoji, size: 32)
        }
        .contextMenu {
            if data.hasSkinTones(parent) {
                SwiftUI.Button(i18n("icu:FunPanelEmojis__ChangeSkinToneButtonLabel")) { chooseTone(for: parent) }
            }
        }
    }
}

/// `FunEmojiPicker`: the emoji panel in a Fun popover.
public struct FunEmojiPicker: View {
    let panel: FunPanelEmojis
    public init(panel: FunPanelEmojis) { self.panel = panel }
    public var body: some View { FunPopoverDialog { panel } }
}
