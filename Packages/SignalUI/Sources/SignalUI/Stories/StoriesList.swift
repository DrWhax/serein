// Ports of ts/components/StoryListItem.dom.tsx, MyStoryButton.dom.tsx, MyStories.dom.tsx,
// StoriesPane.dom.tsx, StoriesAddStoryButton.dom.tsx and StoriesTab.dom.tsx (+ StoryListItem,
// MyStories and Stories .scss): the Stories tab — "My Stories" (add, or the newest sent story
// with its send status), everyone's stories with ring, replies and thumbnail, the hidden
// stories behind a disclosure, My Stories by distribution list, and the empty placeholder.

import SignalI18n
import SwiftUI

/// A story's sender, group or ourselves, as the list shows them.
public struct StoryConversation: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var firstName: String?
    public var color: String
    public var avatar: RGBAImage?
    public var isSignalOfficial: Bool
    public init(id: String, title: String, firstName: String? = nil, color: String = "A200", avatar: RGBAImage? = nil, isSignalOfficial: Bool = false) {
        self.id = id
        self.title = title
        self.firstName = firstName
        self.color = color
        self.avatar = avatar
        self.isSignalOfficial = isSignalOfficial
    }
}

/// `ResolvedSendStatus`
public enum StorySendStatus: Sendable, Hashable { case sending, failed, partiallySent, sent }

/// `StoryViewType`
public struct StoryViewData: Sendable, Hashable, Identifiable {
    public var messageId: String
    public var sender: StoryConversation
    public var attachment: StoryAttachmentData?
    public var isUnread: Bool
    public var timestamp: Date
    public var sendStatus: StorySendStatus
    public var views: Int?
    /// A local copy exists (the download button).
    public var hasLocalFile: Bool
    public var id: String { messageId }
    public init(messageId: String, sender: StoryConversation, attachment: StoryAttachmentData?, isUnread: Bool = false, timestamp: Date,
                sendStatus: StorySendStatus = .sent, views: Int? = nil, hasLocalFile: Bool = false) {
        self.messageId = messageId
        self.sender = sender
        self.attachment = attachment
        self.isUnread = isUnread
        self.timestamp = timestamp
        self.sendStatus = sendStatus
        self.views = views
        self.hasLocalFile = hasLocalFile
    }
}

/// `ConversationStoryType`
public struct ConversationStoryData: Sendable, Hashable, Identifiable {
    public var conversationId: String
    public var group: StoryConversation?
    public var hasReplies: Bool
    public var hasRepliesFromSelf: Bool
    public var storyView: StoryViewData
    public var id: String { conversationId }
    public init(conversationId: String, group: StoryConversation? = nil, hasReplies: Bool = false, hasRepliesFromSelf: Bool = false, storyView: StoryViewData) {
        self.conversationId = conversationId
        self.group = group
        self.hasReplies = hasReplies
        self.hasRepliesFromSelf = hasRepliesFromSelf
        self.storyView = storyView
    }
}

/// `MyStoryType`: one distribution list and our stories in it.
public struct MyStoryList: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var stories: [StoryViewData]
    public var reducedSendStatus: StorySendStatus
    public init(id: String, name: String, stories: [StoryViewData], reducedSendStatus: StorySendStatus = .sent) {
        self.id = id
        self.name = name
        self.stories = stories
        self.reducedSendStatus = reducedSendStatus
    }

    /// `MY_STORY_ID`
    public static let myStoryId = "00000000-0000-0000-0000-000000000000"
}

enum StoryListStyle {
    static let title = LegacyType.body1(weight: 600)
    static let secondary = LegacyType.body2()
}

/// `.StoryListItem__button`: 96px, 10px inline padding, fill-primary on hover.
struct StoryListButton<Content: View>: View {
    let action: (() -> Void)?
    /// Focus-visible (a closed menu returns focus to its trigger): the fill and the focus ring.
    var focused = false
    @ViewBuilder let content: Content
    @State var hovered = false
    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
            .background { if hovered || focused { RoundedRectangle(cornerRadius: 10).fill(AxoColor.fillPrimary) } }
            // Chromium's default focus-visible outline (`auto`: #005FCC, #99C8FF in dark schemes):
            // the row has no axo ring.
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(AxoColor(light: RGBA(hex: 0x005FCC), dark: RGBA(hex: 0x99C8FF)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { action?() }
    }
}

/// `.StoryListItem__previews`: the 46×72 thumbnail (8px corners, gray-60 behind), a tilted
/// card behind it when there are several.
struct StoryPreviewThumbnail: View {
    let attachment: StoryAttachmentData?
    let firstName: String
    let isMe: Bool
    let hasMultiple: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            if hasMultiple {
                RoundedRectangle(cornerRadius: 6).fill(Color(rgba: RGBA(hex: 0x99A8A0))).frame(width: 40, height: 62).rotationEffect(.degrees(-12))
            }
            StoryImage(attachment: attachment, firstName: firstName, isMe: isMe, isThumbnail: true)
                .background(Color(rgba: LegacyColor.gray60))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { if hasMultiple { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(rgba: LegacyColor.gray80), lineWidth: 1) } }
        }
        .frame(width: 46, height: 72, alignment: .topLeading)
    }
}

public struct StoryListItem: View {
    let conversationId: String
    let story: StoryViewData
    let group: StoryConversation?
    let hasReplies: Bool
    let hasRepliesFromSelf: Bool
    let isHidden: Bool
    let onView: () -> Void
    let onViewDetails: () -> Void
    let onGoToConversation: () -> Void
    let onHideStory: () -> Void
    @State var confirmHide = false
    @State var menuLocation: CGPoint?
    @Environment(\.i18n) var i18n

    public init(conversationId: String, story: StoryViewData, group: StoryConversation? = nil, hasReplies: Bool = false, hasRepliesFromSelf: Bool = false,
                isHidden: Bool = false, onView: @escaping () -> Void = {}, onViewDetails: @escaping () -> Void = {},
                onGoToConversation: @escaping () -> Void = {}, onHideStory: @escaping () -> Void = {}) {
        self.conversationId = conversationId
        self.story = story
        self.group = group
        self.hasReplies = hasReplies
        self.hasRepliesFromSelf = hasRepliesFromSelf
        self.isHidden = isHidden
        self.onView = onView
        self.onViewDetails = onViewDetails
        self.onGoToConversation = onGoToConversation
        self.onHideStory = onHideStory
    }

    public var body: some View {
        let shown = group ?? story.sender
        let official = story.sender.isSignalOfficial
        AxoContextMenu.Root(location: $menuLocation) {
            StoryListButton(action: onView) {
                Avatar(strings: AvatarStrings(i18n: i18n), title: shown.title, size: 48, conversationType: .direct, color: shown.color,
                       image: shown.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: shown.avatar != nil,
                       storyRing: story.attachment == nil ? nil : (story.isUnread ? .unread : .read))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        CSSText(shown.title, style: StoryListStyle.title, wrap: .truncate, color: .labelPrimary)
                        if official {
                            CSSText("\u{00A0}", style: StoryListStyle.title, wrap: .nowrap)
                            OfficialChatInlineBadge(size: 14, weight: 600)
                        }
                    }
                    if !official {
                        MessageTimestamp(timestamp: story.timestamp, isRelativeTime: true, style: StoryListStyle.secondary, color: .labelSecondary)
                    }
                    if group == nil && hasRepliesFromSelf {
                        SignalIcon("v3/reply/reply-fill-compact", size: 16, color: .labelSecondary, mask: true).frame(width: 16, height: 16)
                    } else if group != nil && (hasReplies || hasRepliesFromSelf) {
                        SignalIcon("v3/thread/thread-fill-compact", size: 16, color: .labelSecondary, mask: true).frame(width: 16, height: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                StoryPreviewThumbnail(attachment: story.attachment, firstName: story.sender.firstName ?? story.sender.title, isMe: false, hasMultiple: false)
            }
        } items: {
            if isHidden {
                AxoContextMenu.Item(i18n("icu:StoryListItem__unhide"), symbol: "check-circle", action: onHideStory)
            } else {
                AxoContextMenu.Item(i18n("icu:StoryListItem__hide"), symbol: "x-circle") { confirmHide = true }
            }
            if !official {
                AxoContextMenu.Item(i18n("icu:StoryListItem__info"), symbol: "info", action: onViewDetails)
                AxoContextMenu.Item(i18n("icu:StoryListItem__go-to-chat"), symbol: "open", action: onGoToConversation)
            }
        }
        .overlay {
            if confirmHide {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:StoryListItem__hide-modal--body", ["name": .string(story.sender.firstName ?? "")])) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmHide = false }
                        AxoConfirmDialog.Action(i18n("icu:StoryListItem__hide-modal--confirm"), variant: .strongPrimary) {
                            confirmHide = false
                            onHideStory()
                        }
                    }
                }
            }
        }
    }
}

/// `.MyStories__avatar__add-story`: the 20px ultramarine "+" badge with a 2px ring in the
/// list's colour, at the avatar's bottom right.
struct AddStoryBadge: View {
    let hovered: Bool
    var body: some View {
        SignalIcon("v3/plus/plus-compact-bold", size: 12, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white), mask: true)
            .frame(width: 12, height: 12)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color(rgba: LegacyColor.ultramarineDawn)))
            .padding(2)
            .background(Circle().fill(hovered ? AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray65) : AxoColor(light: LegacyColor.gray04, dark: LegacyColor.gray80)))
    }
}

/// `StoriesAddStoryButton`: a menu of "Photo or video" / "Text story".
public struct StoriesAddStoryMenu<Trigger: View>: View {
    let onAddMedia: () -> Void
    let onAddText: () -> Void
    let trigger: Trigger
    @State var open = false
    @Environment(\.i18n) var i18n

    public init(onAddMedia: @escaping () -> Void, onAddText: @escaping () -> Void, @ViewBuilder trigger: () -> Trigger) {
        self.onAddMedia = onAddMedia
        self.onAddText = onAddText
        self.trigger = trigger()
    }

    public var body: some View {
        AxoDropdownMenu.Root(isOpen: $open) {
            trigger.contentShape(Rectangle()).onTapGesture { open.toggle() }
        } items: {
            AxoDropdownMenu.Item(i18n("icu:Stories__add-story--media"), action: onAddMedia)
            AxoDropdownMenu.Item(i18n("icu:Stories__add-story--text"), action: onAddText)
        }
    }
}

public struct MyStoryButton: View {
    let me: StoryConversation
    let myStories: [MyStoryList]
    let onAddMedia: () -> Void
    let onAddText: () -> Void
    let onClick: () -> Void
    @State var hovered = false
    @State var addFocused: Bool
    @Environment(\.i18n) var i18n

    /// - Parameter addButtonFocused: the add-story trigger has focus-visible (as after its menu closes).
    public init(me: StoryConversation, myStories: [MyStoryList], onAddMedia: @escaping () -> Void = {}, onAddText: @escaping () -> Void = {},
                onClick: @escaping () -> Void = {}, addButtonFocused: Bool = false) {
        _addFocused = State(initialValue: addButtonFocused)
        self.me = me
        self.myStories = myStories
        self.onAddMedia = onAddMedia
        self.onAddText = onAddText
        self.onClick = onClick
    }

    func avatar(ring: HasStories?) -> some View {
        Avatar(strings: AvatarStrings(i18n: i18n), title: me.title, size: 48, conversationType: .direct, color: me.color,
               image: me.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: me.avatar != nil, storyRing: ring)
            .overlay(alignment: .bottomTrailing) { AddStoryBadge(hovered: hovered).offset(x: 4, y: 2) }
    }

    /// `getNewestMyStory`
    var newest: StoryViewData? { myStories.first?.stories.max { $0.timestamp < $1.timestamp } }

    /// `reduceStorySendStatus`
    var reducedSendStatus: StorySendStatus {
        myStories.map(\.reducedSendStatus).reduce(.sent) { a, b in
            if a == .failed || b == .failed { return .failed }
            if a == .partiallySent || b == .partiallySent { return .partiallySent }
            if a == .sending || b == .sending { return .sending }
            return .sent
        }
    }

    public var body: some View {
        Group {
            if let newest {
                StoryListButton(action: nil) {
                    StoriesAddStoryMenu(onAddMedia: onAddMedia, onAddText: onAddText) { avatar(ring: .read) }
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 2) {
                                CSSText(i18n("icu:MyStories__list_item"), style: StoryListStyle.title, wrap: .nowrap, color: .labelPrimary)
                                SignalIcon("v3/chevron/chevron-right-compact-bold", size: 16, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.white),
                                           mask: true).frame(width: 16, height: 16)
                            }
                            switch reducedSendStatus {
                            case .sending: CSSText(i18n("icu:Stories__list--sending"), style: StoryListStyle.secondary, color: .labelSecondary)
                            case .failed: failed(i18n("icu:Stories__list--send_failed"))
                            case .partiallySent: failed(i18n("icu:Stories__list--partially-sent"))
                            case .sent: MessageTimestamp(timestamp: newest.timestamp, isRelativeTime: true, style: StoryListStyle.secondary, color: .labelSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        StoryPreviewThumbnail(attachment: newest.attachment, firstName: i18n("icu:you"), isMe: true,
                                              hasMultiple: (myStories.first?.stories.count ?? 0) > 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClick)
                }
            } else {
                StoriesAddStoryMenu(onAddMedia: onAddMedia, onAddText: onAddText) {
                    StoryListButton(action: nil, focused: addFocused) {
                        avatar(ring: nil)
                        VStack(alignment: .leading, spacing: 0) {
                            CSSText(i18n("icu:Stories__mine"), style: StoryListStyle.title, wrap: .truncate, color: .labelPrimary)
                            CSSText(i18n("icu:Stories__add"), style: StoryListStyle.secondary, color: .labelSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
        .onHover { hovered = $0 }
    }

    func failed(_ text: String) -> some View {
        HStack(spacing: 8) {
            SignalIcon("v3/error/error-circle", size: 12, color: .labelDestructive, mask: true).frame(width: 12, height: 12)
            CSSText(text, style: StoryListStyle.secondary, color: .labelSecondary)
        }
    }
}

/// `StoriesPane`: the search, My Stories, everyone's stories and the hidden ones.
public struct StoriesPane: View {
    let me: StoryConversation
    let myStories: [MyStoryList]
    let stories: [ConversationStoryData]
    let hiddenStories: [ConversationStoryData]
    let actions: StoriesActions
    @State var searchTerm = ""
    @State var showingHidden = false
    @Environment(\.i18n) var i18n

    public init(me: StoryConversation, myStories: [MyStoryList], stories: [ConversationStoryData], hiddenStories: [ConversationStoryData],
                actions: StoriesActions) {
        self.me = me
        self.myStories = myStories
        self.stories = stories
        self.hiddenStories = hiddenStories
        self.actions = actions
    }

    /// `search`: by the sender's or group's title.
    var rendered: [ConversationStoryData] {
        let q = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return stories }
        return stories.filter { ($0.group?.title ?? $0.storyView.sender.title).lowercased().contains(q) }
    }

    func item(_ s: ConversationStoryData, hidden: Bool) -> some View {
        StoryListItem(conversationId: s.conversationId, story: s.storyView, group: s.group, hasReplies: s.hasReplies, hasRepliesFromSelf: s.hasRepliesFromSelf,
                      isHidden: hidden, onView: { actions.viewUserStories(s.conversationId, false) },
                      onViewDetails: { actions.viewUserStories(s.conversationId, true) },
                      onGoToConversation: { actions.showConversation(s.conversationId) }, onHideStory: { actions.toggleHideStories(s.conversationId) })
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavSidebarSearchHeader { SearchInput(value: $searchTerm, placeholder: i18n("icu:search"), onClear: { searchTerm = "" }) }
            StaticAwareScrollView {
                VStack(spacing: 0) {
                    MyStoryButton(me: me, myStories: myStories, onAddMedia: actions.onAddMedia, onAddText: actions.onAddText, onClick: actions.onMyStoriesClicked)
                    ForEach(rendered) { item($0, hidden: false) }
                    if !hiddenStories.isEmpty {
                        Button { showingHidden.toggle() } label: {
                            HStack(spacing: 0) {
                                CSSText(i18n("icu:Stories__hidden-stories"), style: StoryListStyle.title, wrap: .nowrap, color: .labelPrimary)
                                Spacer(minLength: 0)
                                SignalIcon(showingHidden ? "v3/chevron/chevron-down" : "v3/chevron/chevron-right", size: 16,
                                           color: showingHidden ? .labelSecondary : .labelPrimary, mask: true).frame(width: 16, height: 16)
                            }
                            .padding(.vertical, 12).padding(.horizontal, 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(UndimmedButtonStyle())
                        if showingHidden { ForEach(hiddenStories) { item($0, hidden: true) } }
                    }
                }
                .padding(.leading, 11).padding(.trailing, 22)     // the scrollbar gutter (stable) and 11px
            }
        }
        .overlay {
            if stories.isEmpty {
                NavSidebarEmpty(title: i18n("icu:Stories__list__empty--title"), subtitle: i18n("icu:Stories__list__empty--subtitle"))
            }
        }
    }
}

/// What the Stories tab asks the app to do.
public struct StoriesActions {
    public var onAddMedia: () -> Void = {}
    public var onAddText: () -> Void = {}
    public var onMyStoriesClicked: () -> Void = {}
    /// (conversation id, open the details)
    public var viewUserStories: (String, Bool) -> Void = { _, _ in }
    public var showConversation: (String) -> Void = { _ in }
    public var toggleHideStories: (String) -> Void = { _ in }
    public var showStoriesSettings: () -> Void = {}
    public var viewStory: (String) -> Void = { _ in }
    public var deleteStoryForEveryone: (StoryViewData) -> Void = { _ in }
    public var forwardStory: (StoryViewData) -> Void = { _ in }
    public var saveStory: (StoryViewData) -> Void = { _ in }
    public var retryMessageSend: (String) -> Void = { _ in }
    public var onToggleNavTabsCollapse: (Bool) -> Void = { _ in }
    public var savePreferredLeftPaneWidth: (CGFloat) -> Void = { _ in }
    public init() {}
}

extension MyStoryList {
    /// `getStoryDistributionListName`: My Story by its id, else the list's name.
    @MainActor func displayName(_ i18n: Localizer) -> String { id == Self.myStoryId ? i18n("icu:Stories__mine") : name }
}

/// `MyStories`: our sent stories by distribution list, each with its send status (retry on
/// failure) or views, download and more (forward, info, delete — confirmed).
public struct MyStories: View {
    let myStories: [MyStoryList]
    let hasViewReceiptSetting: Bool
    let preferredLeftPaneWidth: CGFloat
    let navTabsCollapsed: Bool
    let onBack: () -> Void
    let actions: StoriesActions
    let focusedMoreStoryId: String?
    let focusedMoreShowsTooltip: Bool
    @State var confirmDelete: StoryViewData?
    @State var retried: Set<String> = []
    @Environment(\.i18n) var i18n

    /// - Parameters:
    ///   - focusedMoreStoryId: the story whose more button has focus-visible (a closed menu
    ///     returns focus to its trigger).
    ///   - focusedMoreShowsTooltip: its tooltip is open (Radix opens tooltips on focus).
    public init(myStories: [MyStoryList], hasViewReceiptSetting: Bool, preferredLeftPaneWidth: CGFloat, navTabsCollapsed: Bool = false,
                onBack: @escaping () -> Void, actions: StoriesActions, focusedMoreStoryId: String? = nil, focusedMoreShowsTooltip: Bool = true) {
        self.focusedMoreShowsTooltip = focusedMoreShowsTooltip
        self.myStories = myStories
        self.hasViewReceiptSetting = hasViewReceiptSetting
        self.preferredLeftPaneWidth = preferredLeftPaneWidth
        self.navTabsCollapsed = navTabsCollapsed
        self.onBack = onBack
        self.actions = actions
        self.focusedMoreStoryId = focusedMoreStoryId
    }

    func detailsText(_ s: String) -> some View {
        CSSText(s, style: StoryListStyle.title, wrap: .wrap, color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
    }

    func failed(_ text: String, _ story: StoryViewData) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SignalIcon("v3/error/error-circle", size: 12, color: AxoColor(light: LegacyColor.accentRed, dark: LegacyColor.accentRed), mask: true)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                detailsText(text)
                if !retried.contains(story.messageId) {
                    CSSText(i18n("icu:Stories__list--retry-send"), style: LegacyType.subtitle(), wrap: .wrap,
                            color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray25))
                }
            }
        }
    }

    func row(_ story: StoryViewData) -> some View {
        HStack(spacing: 0) {
            StoryListButton(action: {
                if !retried.contains(story.messageId) && (story.sendStatus == .failed || story.sendStatus == .partiallySent) {
                    retried.insert(story.messageId)
                    actions.retryMessageSend(story.messageId)
                } else {
                    actions.viewStory(story.messageId)
                }
            }) {
                StoryPreviewThumbnail(attachment: story.attachment, firstName: i18n("icu:you"), isMe: true, hasMultiple: false)
                VStack(alignment: .leading, spacing: 0) {
                    switch story.sendStatus {
                    case .sending: detailsText(i18n("icu:Stories__list--sending"))
                    case .failed: failed(i18n("icu:Stories__list--send_failed"), story)
                    case .partiallySent: failed(i18n("icu:Stories__list--partially-sent"), story)
                    case .sent:
                        detailsText(hasViewReceiptSetting ? i18n("icu:MyStories__views", ["views": .number(Double(story.views ?? 0))])
                                    : i18n("icu:MyStories__views-off"))
                        MessageTimestamp(timestamp: story.timestamp, isRelativeTime: true, style: LegacyType.body1(),
                                         color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray25))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            }
            .accessibilityLabel(i18n("icu:MyStories__story"))
            if story.hasLocalFile {
                Button { actions.saveStory(story) } label: {
                    SignalIcon("v3/save/save-compact", size: 18, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray15), mask: true)
                        .frame(width: 18, height: 18)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray65)))
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel(i18n("icu:MyStories__download"))
            }
            MyStoryMoreMenu(story: story, autoFocus: story.messageId == focusedMoreStoryId, showsTooltip: focusedMoreShowsTooltip, actions: actions) {
                confirmDelete = story
            }
                .padding(.leading, 16)
        }
        .padding(.trailing, 10)
        .frame(height: 96)
    }

    public var body: some View {
        NavSidebar(title: i18n("icu:MyStories__title"), navTabsCollapsed: navTabsCollapsed, onBack: onBack,
                   onToggleNavTabsCollapse: actions.onToggleNavTabsCollapse, preferredLeftPaneWidth: preferredLeftPaneWidth, requiresFullWidth: true,
                   savePreferredLeftPaneWidth: actions.savePreferredLeftPaneWidth) {
            EmptyView()
        } content: {
            if myStories.isEmpty {
                CSSText(i18n("icu:Stories__list-empty"), style: LegacyType.body1(), alignment: .center,
                        color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StaticAwareScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(myStories) { list in
                            CSSText(list.displayName(i18n), style: StoryListStyle.title, wrap: .truncate,
                                    color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                                .padding(.top, 24).padding(.bottom, 8).padding(.horizontal, 10)
                            ForEach(list.stories) { row($0) }
                        }
                    }
                    .padding(.leading, 11).padding(.trailing, 22)     // the scrollbar gutter (stable) and 11px
                }
            }
        }
        .overlay {
            if let story = confirmDelete {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:MyStories__delete")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmDelete = nil }
                        AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                            confirmDelete = nil
                            actions.deleteStoryForEveryone(story)
                        }
                    }
                }
            }
        }
    }
}

/// `MyStories__story__more`: forward, info, delete.
struct MyStoryMoreMenu: View {
    let story: StoryViewData
    let autoFocus: Bool
    let showsTooltip: Bool
    let actions: StoriesActions
    let onDelete: () -> Void
    @State var open = false
    @Environment(\.i18n) var i18n

    var body: some View {
        AxoDropdownMenu.Root(isOpen: $open) {
            // Radix opens the tooltip on keyboard focus too (a closed menu returns focus here).
            AxoTooltip.Root(label: i18n("icu:MyStories__more"), forceOpen: autoFocus && showsTooltip && !open) {
                AxoIconButton.Root(label: i18n("icu:MyStories__more"), tooltip: false, variant: .strongSecondary, size: .sm, symbol: "more",
                                   autoFocus: autoFocus) { open.toggle() }
            }
        } items: {
            AxoDropdownMenu.Item(i18n("icu:forward"), symbol: "forward") { actions.forwardStory(story) }
            AxoDropdownMenu.Item(i18n("icu:StoryListItem__info"), symbol: "info") { actions.viewStory(story.messageId) }
            AxoDropdownMenu.Item(i18n("icu:delete"), symbol: "trash", action: onDelete)
        }
    }
}

/// `StoriesTab`: the list (or My Stories) and, beside it, the placeholder.
public struct StoriesTab<StoryCreatorView: View>: View {
    let me: StoryConversation
    let myStories: [MyStoryList]
    let stories: [ConversationStoryData]
    let hiddenStories: [ConversationStoryData]
    let hasViewReceiptSetting: Bool
    let preferredLeftPaneWidth: CGFloat
    let navTabsCollapsed: Bool
    let otherTabsUnreadCount: Int
    let hasFailedStorySends: Bool
    let hasPendingUpdate: Bool
    let isCreatingStory: Bool
    let actions: StoriesActions
    let renderStoryCreator: () -> StoryCreatorView
    @State var isMyStories = false
    @State var moreOpen = false
    @Environment(\.i18n) var i18n

    public init(me: StoryConversation, myStories: [MyStoryList], stories: [ConversationStoryData], hiddenStories: [ConversationStoryData],
                hasViewReceiptSetting: Bool, preferredLeftPaneWidth: CGFloat, navTabsCollapsed: Bool = false, otherTabsUnreadCount: Int = 0,
                hasFailedStorySends: Bool = false, hasPendingUpdate: Bool = false, isCreatingStory: Bool = false, actions: StoriesActions,
                @ViewBuilder renderStoryCreator: @escaping () -> StoryCreatorView) {
        self.me = me
        self.myStories = myStories
        self.stories = stories
        self.hiddenStories = hiddenStories
        self.hasViewReceiptSetting = hasViewReceiptSetting
        self.preferredLeftPaneWidth = preferredLeftPaneWidth
        self.navTabsCollapsed = navTabsCollapsed
        self.otherTabsUnreadCount = otherTabsUnreadCount
        self.hasFailedStorySends = hasFailedStorySends
        self.hasPendingUpdate = hasPendingUpdate
        self.isCreatingStory = isCreatingStory
        self.actions = actions
        self.renderStoryCreator = renderStoryCreator
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isMyStories && !myStories.isEmpty {
                MyStories(myStories: myStories, hasViewReceiptSetting: hasViewReceiptSetting, preferredLeftPaneWidth: preferredLeftPaneWidth,
                          navTabsCollapsed: navTabsCollapsed, onBack: { isMyStories = false }, actions: actions)
            } else {
                NavSidebar(title: i18n("icu:Stories__title"), hasFailedStorySends: hasFailedStorySends, hasPendingUpdate: hasPendingUpdate,
                           navTabsCollapsed: navTabsCollapsed, onToggleNavTabsCollapse: actions.onToggleNavTabsCollapse,
                           preferredLeftPaneWidth: preferredLeftPaneWidth, requiresFullWidth: true,
                           savePreferredLeftPaneWidth: actions.savePreferredLeftPaneWidth, otherTabsUnreadCount: otherTabsUnreadCount) {
                    StoriesAddStoryMenu(onAddMedia: actions.onAddMedia, onAddText: actions.onAddText) {
                        AxoIconButton.Root(label: i18n("icu:Stories__add"), variant: .impliedSecondary, size: .sm, symbol: "plus")
                    }
                    AxoDropdownMenu.Root(isOpen: $moreOpen) {
                        AxoIconButton.Root(label: i18n("icu:StoriesTab__MoreActionsLabel"), variant: .impliedSecondary, size: .sm, symbol: "more") {
                            moreOpen.toggle()
                        }
                    } items: {
                        AxoDropdownMenu.Item(i18n("icu:StoriesSettings__context-menu"), symbol: "lock", action: actions.showStoriesSettings)
                    }
                } content: {
                    StoriesPane(me: me, myStories: myStories, stories: stories, hiddenStories: hiddenStories, actions: {
                        var a = actions
                        let onMyStories = actions.onAddText
                        a.onMyStoriesClicked = { if myStories.isEmpty { onMyStories() } else { isMyStories = true } }
                        return a
                    }())
                }
            }
            placeholder
        }
        .background(AxoColor.surfacePrimary)
        .overlay { if isCreatingStory { renderStoryCreator() } }
    }

    /// `Stories__placeholder`: the 40px stories glyph and the hint, at 70%.
    var placeholder: some View {
        let ink = AxoColor.labelSecondary
        return VStack(spacing: 12) {
            SignalIcon("v3/stories/stories-display-bold", size: 40, color: ink, mask: true).frame(width: 40, height: 40)
            if stories.isEmpty {
                let rich = i18n.richText("icu:Stories__placeholder-with-icon--text-2", ["newStoryButtonIcon": .element("icon")])
                AxoInlineFlowText(pieces: rich.runs.map { run in
                    switch run.content {
                    case .text(let s): AxoInlinePiece.text(s)
                    case .element: AxoInlinePiece.glyph(AxoSymbol.inlineGlyph("plus"))
                    }
                }, style: LegacyType.body1(), alignment: .center, maxLines: nil) { _ in }
                    .cssTextColor(ink)
            } else {
                CSSText(i18n("icu:Stories__placeholder--text"), style: LegacyType.body1(), alignment: .center, color: ink)
            }
        }
        .opacity(0.7)
        .padding(.top, 78).padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
