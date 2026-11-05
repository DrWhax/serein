// Ports of ts/components/conversation/media-gallery/MediaGallery.dom.tsx, PanelHeader.dom.tsx and
// groupMediaItemsByDate.std.ts, with the ConversationPanel frame (stylesheets/components/
// ConversationPanel.scss): "All media". The header has the back button, the Media / Audio /
// Links / Files segmented control and the sort menu. The body is the current tab's items in
// date sections (Today, Yesterday, This week, This month, then "MMMM YYYY") in a 360–660px
// column, or one section by size, or the tab's empty state.

import SignalI18n
import SwiftUI

public enum MediaSortOrder: String, Sendable { case date, size }

/// One gallery entry: what it is (which row or tile shows it) and when it arrived.
public struct GalleryMediaItem: Identifiable {
    public enum Kind {
        case media(MessageAttachment)
        case document(MessageAttachment)
        case audio(MessageAttachment, duration: Double, peaks: [Double]?, isVoiceMessage: Bool, isPlayed: Bool)
        case link(LinkPreview)
        case contact(name: String, avatar: MessageAttachment?)
    }
    public var id: String
    public var kind: Kind
    public var message: MediaItemMessage
    public var authorTitle: String
    public init(id: String, kind: Kind, message: MediaItemMessage, authorTitle: String) {
        self.id = id
        self.kind = kind
        self.message = message
        self.authorTitle = authorTitle
    }
    var isGrid: Bool { if case .media = kind { true } else { false } }
    var size: Int {
        switch kind {
        case .media(let a), .document(let a), .audio(let a, _, _, _, _): a.size
        case .link(let p): p.image?.size ?? 0
        case .contact(_, let a): a?.size ?? 0
        }
    }
}

/// `groupMediaItemsByDate`: newest first, in Today / Yesterday / This week / This month and then
/// one section per month.
public enum MediaGalleryGrouping {
    public enum Section: Hashable {
        case today, yesterday, thisWeek, thisMonth
        case yearMonth(year: Int, month: Int)
    }

    public static func group(_ items: [GalleryMediaItem], now: Date, calendar: Calendar) -> [(Section, [GalleryMediaItem])] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let thisWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        var buckets: [Section: [GalleryMediaItem]] = [:]
        for item in items.sorted(by: { $0.message.receivedAt > $1.message.receivedAt }) {
            let t = item.message.receivedAt
            let s: Section = t > today ? .today : t > yesterday ? .yesterday : t > thisWeek ? .thisWeek : t > thisMonth ? .thisMonth
                : .yearMonth(year: calendar.component(.year, from: t), month: calendar.component(.month, from: t))
            buckets[s, default: []].append(item)
        }
        let fixed: [Section] = [.today, .yesterday, .thisWeek, .thisMonth]
        let months = buckets.keys.compactMap { s -> (Int, Section)? in
            if case .yearMonth(let y, let m) = s { return (y * 100 + m, s) }
            return nil
        }.sorted { $0.0 > $1.0 }.map(\.1)
        return (fixed + months).compactMap { s in buckets[s].map { (s, $0) } }
    }
}

/// `.ConversationPanel`: the 52px header (a 20px back chevron, 24px in) over the body.
public struct ConversationPanel<Header: View, Content: View>: View {
    let onBack: () -> Void
    let header: Header
    let content: Content
    @Environment(\.i18n) var i18n

    public init(onBack: @escaping () -> Void, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.onBack = onBack
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                SwiftUI.Button(action: onBack) {
                    SignalIcon("v3/chevron/chevron-left", size: 20, color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray02))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:goBack"))
                .padding(.leading, 24).padding(.trailing, 6)
                header.frame(maxWidth: .infinity)
            }
            .frame(height: 52)
            .cssTextColor(.labelPrimary)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AxoColor.surfacePrimary)
    }
}

/// `PanelHeader` of the gallery.
public struct MediaGalleryPanelHeader: View {
    @Binding var tab: MediaGalleryTab
    @Binding var sortOrder: MediaSortOrder
    @State private var sortMenuOpen = false
    @Environment(\.i18n) var i18n

    public init(tab: Binding<MediaGalleryTab>, sortOrder: Binding<MediaSortOrder>) {
        _tab = tab
        _sortOrder = sortOrder
    }

    public var body: some View {
        let value = Binding<String?>(get: { tab.rawValue }, set: { if let v = $0, let t = MediaGalleryTab(rawValue: v) { tab = t } })
        HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: 0)
            ExperimentalAxoSegmentedControl.Root(label: nil, width: .full, itemWidth: .equal, variant: .noTrack, value: value) {
                ExperimentalAxoSegmentedControl.Item(value: "media") { ExperimentalAxoSegmentedControl.ItemText(i18n("icu:media")) }
                ExperimentalAxoSegmentedControl.Item(value: "audio") { ExperimentalAxoSegmentedControl.ItemText(i18n("icu:MediaGallery__tab__audio")) }
                ExperimentalAxoSegmentedControl.Item(value: "links") { ExperimentalAxoSegmentedControl.ItemText(i18n("icu:MediaGallery__tab__links")) }
                ExperimentalAxoSegmentedControl.Item(value: "documents") { ExperimentalAxoSegmentedControl.ItemText(i18n("icu:MediaGallery__tab__files")) }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
            AxoDropdownMenu.Root(isOpen: $sortMenuOpen) {
                AxoIconButton.Root(label: i18n("icu:MediaGallery__sort"), variant: sortOrder == .date ? .impliedSecondary : .strongPrimary, size: .md,
                                   symbol: "arrow-up-down")
            } items: {
                AxoDropdownMenu.Label(i18n("icu:MediaGallery__sort--header"))
                AxoDropdownMenu.CheckboxItem(i18n("icu:MediaGallery__sort__date"), checked: Binding(get: { sortOrder == .date }, set: { _ in sortOrder = .date }))
                AxoDropdownMenu.CheckboxItem(i18n("icu:MediaGallery__sort__size"), checked: Binding(get: { sortOrder == .size }, set: { _ in sortOrder = .size }))
            }
            Color.clear.frame(width: 18, height: 1)
        }
    }
}

public struct MediaGallery: View {
    let items: [GalleryMediaItem]
    let tab: MediaGalleryTab
    let sortOrder: MediaSortOrder
    let loading: Bool
    let onItemClick: (GalleryMediaItem) -> Void
    let showMessage: (GalleryMediaItem) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(items: [GalleryMediaItem], tab: MediaGalleryTab, sortOrder: MediaSortOrder = .date, loading: Bool = false,
                onItemClick: @escaping (GalleryMediaItem) -> Void = { _ in }, showMessage: @escaping (GalleryMediaItem) -> Void = { _ in }) {
        self.items = items
        self.tab = tab
        self.sortOrder = sortOrder
        self.loading = loading
        self.onItemClick = onItemClick
        self.showMessage = showMessage
    }

    func header(_ s: MediaGalleryGrouping.Section, _ first: GalleryMediaItem) -> String {
        switch s {
        case .today: return i18n("icu:today")
        case .yesterday: return i18n("icu:yesterday")
        case .thisWeek: return i18n("icu:thisWeek")
        case .thisMonth: return i18n("icu:thisMonth")
        case .yearMonth:
            let f = DateFormatter()
            f.locale = Locale(identifier: i18n.locale)
            f.timeZone = timeZone
            f.dateFormat = "MMMM yyyy"
            return f.string(from: first.message.receivedAt)
        }
    }

    @ViewBuilder func row(_ item: GalleryMediaItem) -> some View {
        let click = { onItemClick(item) }, show = { showMessage(item) }
        switch item.kind {
        case .media(let a): MediaGridItem(attachment: a, showSize: sortOrder == .size, onClick: click)
        case .document(let a): DocumentListItem(attachment: a, message: item.message, authorTitle: item.authorTitle, onClick: click, showMessage: show)
        case .audio(let a, let duration, let peaks, let voice, let played):
            AudioListItem(attachment: a, message: item.message, authorTitle: item.authorTitle, isVoiceMessage: voice, duration: duration, peaks: peaks,
                          isPlayed: played, onClick: click, showMessage: show)
        case .link(let p): LinkPreviewItem(preview: p, message: item.message, authorTitle: item.authorTitle, onClick: click, showMessage: show)
        case .contact(let name, let avatar):
            GalleryContactListItem(name: name, avatar: avatar, message: item.message, authorTitle: item.authorTitle, onClick: click, showMessage: show)
        }
    }

    public var body: some View {
        if items.isEmpty {
            if loading { Color.clear } else { MediaGalleryEmptyState(tab: tab) }
        } else {
            let isGrid = items.first?.isGrid ?? false
            let kind: AttachmentSection<EmptyView>.Kind = isGrid ? .media : .list
            VStack(alignment: .leading, spacing: 0) {
                if sortOrder == .size {
                    AttachmentSection(header: nil, kind: isGrid ? .media : .list) {
                        ForEach(items.sorted { $0.size > $1.size }) { row($0) }
                    }
                } else {
                    var calendar = Calendar(identifier: .gregorian)
                    let _ = (calendar.timeZone = timeZone)
                    let sections = MediaGalleryGrouping.group(items, now: fixedNow ?? .now, calendar: calendar)
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        AttachmentSection(header: header(section.0, section.1[0]), kind: kind == .media ? .media : .list) {
                            ForEach(section.1) { row($0) }
                        }
                        if !isGrid && index < sections.count - 1 {
                            // mx-4 my-3 border-[0.5px] border-primary
                            Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                }
            }
            .frame(minWidth: 360, maxWidth: 660)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
