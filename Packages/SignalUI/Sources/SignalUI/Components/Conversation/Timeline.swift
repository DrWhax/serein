// Port of ts/components/conversation/Timeline.dom.tsx (+ `.module-timeline*` in
// stylesheets/_modules.scss): the conversation's scrolling message list. From the top: the
// hero row (once the oldest message is loaded), each item (the last-seen indicator just
// above the oldest unseen one), the Signal-chat spacer, the typing bubble (once the newest
// message is loaded); 6px + 1px below. Short timelines sit at the bottom unless the oldest
// message is loaded. Over it: the floating date header and the scroll-down buttons.
//
// Items are rendered lazily (LazyVStack); visibility comes from the scroll view rather than
// upstream's IntersectionObserver.

import SignalI18n
import SwiftUI

/// `UnreadIndicatorPlacement`
public enum UnreadIndicatorPlacement: Sendable, Hashable { case justAbove, justBelow }

/// `RenderItemProps` (the parts that are not the conversation's own props).
public struct TimelineRenderItemProps: Sendable, Hashable {
    public var id: String
    public var index: Int
    public var previousMessageId: String?
    public var nextMessageId: String?
    public var isOldestTimelineItem: Bool
    public var unreadIndicatorPlacement: UnreadIndicatorPlacement?
    public var containerWidthBreakpoint: WidthBreakpoint
}

extension WidthBreakpoint {
    /// `getWidthBreakpoint` (ts/util/timelineUtil.std.ts)
    public static func timeline(_ width: CGFloat) -> WidthBreakpoint { width > 606 ? .wide : width > 514 ? .medium : .narrow }
}

extension EnvironmentValues {
    /// The window's width (CSS `100vw`); the timeline's own width when unset.
    @Entry public var viewportWidth: CGFloat? = nil
}

public struct Timeline<Item: View, Hero: View, Typing: View>: View {
    let id: String
    let items: [String]
    let haveNewest: Bool
    let haveOldest: Bool
    let isConversationSelected: Bool
    let isSignalConversation: Bool
    let isLoadingMessages: Bool
    let oldestUnseenIndex: Int?
    let totalUnseen: Int
    let unreadCount: Int
    let unreadMentionsCount: Int
    let isNearBottom: Bool?
    let scrollToIndex: Int?
    let scrollToIndexCounter: Int
    let getTimestampForMessage: (String) -> Date?
    let renderItem: (TimelineRenderItemProps) -> Item
    let renderHeroRow: () -> Hero
    let renderTypingBubble: () -> Typing
    let loadOlderMessages: (String) -> Void
    let loadNewerMessages: (String) -> Void
    let loadNewestMessages: (String) -> Void
    let setIsNearBottom: (String, Bool) -> Void
    let scrollToOldestUnreadMention: (String) -> Void
    let markMessageRead: (String) -> Void

    @State private var hasRecentlyScrolled = true
    @State private var visibleIds: [String] = []
    @State private var width: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @Environment(\.i18n) var i18n
    @Environment(\.viewportWidth) var viewportWidth
    @Environment(\.axoStaticRendering) var staticRendering

    public init(id: String, items: [String], haveNewest: Bool, haveOldest: Bool, isConversationSelected: Bool = true,
                isSignalConversation: Bool = false, isLoadingMessages: Bool = false, oldestUnseenIndex: Int? = nil, totalUnseen: Int = 0,
                unreadCount: Int = 0, unreadMentionsCount: Int = 0, isNearBottom: Bool? = nil, scrollToIndex: Int? = nil,
                scrollToIndexCounter: Int = 0, getTimestampForMessage: @escaping (String) -> Date?,
                @ViewBuilder renderItem: @escaping (TimelineRenderItemProps) -> Item, @ViewBuilder renderHeroRow: @escaping () -> Hero,
                @ViewBuilder renderTypingBubble: @escaping () -> Typing, loadOlderMessages: @escaping (String) -> Void = { _ in },
                loadNewerMessages: @escaping (String) -> Void = { _ in }, loadNewestMessages: @escaping (String) -> Void = { _ in },
                setIsNearBottom: @escaping (String, Bool) -> Void = { _, _ in }, scrollToOldestUnreadMention: @escaping (String) -> Void = { _ in },
                markMessageRead: @escaping (String) -> Void = { _ in }) {
        self.id = id
        self.items = items
        self.haveNewest = haveNewest
        self.haveOldest = haveOldest
        self.isConversationSelected = isConversationSelected
        self.isSignalConversation = isSignalConversation
        self.isLoadingMessages = isLoadingMessages
        self.oldestUnseenIndex = oldestUnseenIndex
        self.totalUnseen = totalUnseen
        self.unreadCount = unreadCount
        self.unreadMentionsCount = unreadMentionsCount
        self.isNearBottom = isNearBottom
        self.scrollToIndex = scrollToIndex
        self.scrollToIndexCounter = scrollToIndexCounter
        self.getTimestampForMessage = getTimestampForMessage
        self.renderItem = renderItem
        self.renderHeroRow = renderHeroRow
        self.renderTypingBubble = renderTypingBubble
        self.loadOlderMessages = loadOlderMessages
        self.loadNewerMessages = loadNewerMessages
        self.loadNewestMessages = loadNewestMessages
        self.setIsNearBottom = setIsNearBottom
        self.scrollToOldestUnreadMention = scrollToOldestUnreadMention
        self.markMessageRead = markMessageRead
    }

    static var atBottomThreshold: CGFloat { 15 }

    var widthBreakpoint: WidthBreakpoint { .timeline(width) }

    /// `.module-message__container-outer` max-width for the breakpoint.
    var messageMaxWidth: CGFloat {
        switch widthBreakpoint {
        case .wide: (viewportWidth ?? width) / 2
        case .medium: 370
        case .narrow: min(306, width - 38)
        }
    }

    /// The oldest item at least partly on screen (the first item before anything is known).
    var oldestVisibleId: String? { items.first { visibleIds.contains($0) } ?? items.first }
    var newestVisibleId: String? { items.last { visibleIds.contains($0) } ?? items.last }

    public var body: some View {
        // Only the open conversation's timeline renders anything.
        if isConversationSelected {
            if staticRendering { staticContent } else { content }
        }
    }

    /// Offscreen rendering (no ScrollView): the content laid out at rest, scrolled to the
    /// bottom (as a conversation opens), clipped to the timeline.
    var staticContent: some View {
        VStack(spacing: 0) {
            if !haveOldest { Spacer(minLength: 0) }
            rows(lazy: false)
            if haveOldest { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.messageContainerMaxWidth, messageMaxWidth)
        .clipped()
        .overlay(alignment: .top) { floatingHeader }
        .overlay(alignment: .bottomTrailing) { scrollDownButtons }
        .overlay(alignment: .bottom) { signalChip }
    }

    var content: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if !haveOldest { Spacer(minLength: 0) }      // justify-content: flex-end
                rows(lazy: true)
                if haveOldest { Spacer(minLength: 0) }
            }
            .frame(minHeight: 0)
            .containerRelativeFrame(.vertical, alignment: .top) { length, _ in length }
            .fixedSize(horizontal: false, vertical: false)
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .onScrollTargetVisibilityChange(idType: String.self) { visibleIds = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentSize.height - geo.visibleRect.maxY
        } action: { _, bottom in
            onScroll(distanceFromBottom: bottom)
        }
        .onScrollGeometryChange(for: Bool.self) { geo in geo.contentOffset.y < 100 } action: { _, nearTop in
            if nearTop && !haveOldest, let first = items.first { loadOlderMessages(first) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.messageContainerMaxWidth, messageMaxWidth)
        .overlay(alignment: .top) { floatingHeader }
        .overlay(alignment: .bottomTrailing) { scrollDownButtons }
        .overlay(alignment: .bottom) { signalChip }
        .onChange(of: scrollToIndexCounter) { if let scrollToIndex { scrollTo(index: scrollToIndex) } }
        .onAppear { if let scrollToIndex { scrollTo(index: scrollToIndex) } }
        .task(id: hasRecentlyScrolled) {
            guard hasRecentlyScrolled else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { hasRecentlyScrolled = false }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder func rows(lazy: Bool) -> some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) { messages }.scrollTargetLayout().padding(.bottom, 6 + 1)
        } else {
            VStack(alignment: .leading, spacing: 0) { messages }.padding(.bottom, 6 + 1)
        }
    }

    @ViewBuilder var messages: some View {
            if haveOldest { renderHeroRow() }
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if oldestUnseenIndex == index {
                    LastSeenIndicator(count: totalUnseen)
                }
                renderItem(TimelineRenderItemProps(
                    id: item, index: index,
                    previousMessageId: index > 0 ? items[index - 1] : nil,
                    nextMessageId: index + 1 < items.count ? items[index + 1] : nil,
                    isOldestTimelineItem: haveOldest && index == 0,
                    unreadIndicatorPlacement: oldestUnseenIndex == index ? .justAbove : oldestUnseenIndex == index + 1 ? .justBelow : nil,
                    containerWidthBreakpoint: widthBreakpoint))
                    .frame(maxWidth: .infinity)
                    .id(item)
            }
            // Room for the absolutely-positioned official-chat chip.
            if isSignalConversation { Color.clear.frame(height: 64) }
            if haveNewest { renderTypingBubble() }
        // (rows: padding-bottom 6px + the 1px ::after)
    }

    @ViewBuilder var floatingHeader: some View {
        if let oldest = oldestVisibleId, let timestamp = getTimestampForMessage(oldest) {
            TimelineFloatingHeader(timestamp: timestamp,
                                   visible: (hasRecentlyScrolled || isLoadingMessages) && (!haveOldest || oldest != items.first),
                                   isLoading: isLoadingMessages)
        }
    }

    @ViewBuilder var scrollDownButtons: some View {
        if !items.isEmpty && isNearBottom == false {
            let below = !haveNewest || (newestVisibleId != nil && newestVisibleId != items.last)
            VStack(spacing: 14) {
                if unreadMentionsCount > 0 {
                    ScrollDownButton(variant: .unreadMentions, count: unreadMentionsCount) { scrollToOldestUnreadMention(id) }
                }
                ScrollDownButton(variant: .unreadMessages, count: unreadCount > 0 && below ? unreadCount : 0) { scrollDown() }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
        }
    }

    /// The official chat's "Only Signal can message you here" style chip, 20px from the bottom.
    @ViewBuilder var signalChip: some View {
        if isSignalConversation {
            CSSText(i18n("icu:Timeline--signal-official-chat--chip"), style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 24).fill(AxoColor.legacySignalConversationBg))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
                .frame(maxWidth: .infinity)
                .padding(.trailing, 14)
                .padding(.bottom, 20)
        }
    }

    func onScroll(distanceFromBottom: CGFloat) {
        let atBottom = distanceFromBottom <= Self.atBottomThreshold
        if isNearBottom != atBottom { setIsNearBottom(id, atBottom) }
        // The floating header shows while scrolling through history (not for new messages
        // or the typing bubble arriving at the bottom).
        if hasRecentlyScrolled || !atBottom { hasRecentlyScrolled = true }
        if atBottom, !haveNewest, let last = items.last { loadNewerMessages(last) }
        if let newest = newestVisibleId { markMessageRead(newest) }
    }

    func scrollTo(index: Int) {
        if index < 0 || index >= items.count {
            scrollPosition.scrollTo(edge: .bottom)
        } else {
            scrollPosition.scrollTo(id: items[index], anchor: .center)
        }
    }

    /// `#scrollDown`: to the oldest unseen message if it is below, else load or go to the newest.
    func scrollDown() {
        if !haveNewest {
            loadNewestMessages(id)
        } else if let oldestUnseenIndex, oldestUnseenIndex < items.count, let newest = newestVisibleId,
                  let newestIndex = items.firstIndex(of: newest), oldestUnseenIndex > newestIndex {
            scrollPosition.scrollTo(id: items[oldestUnseenIndex], anchor: .top)
        } else {
            withAnimation { scrollPosition.scrollTo(edge: .bottom) }
        }
    }
}
