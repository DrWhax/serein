// Port of ts/components/StoryViewsNRepliesModal.dom.tsx (+ stylesheets/components/
// StoryViewsNRepliesModal.scss): the dark modal in the bottom-right corner of the story
// viewer with who viewed a story ("Views") and the group's replies and reactions ("Replies"),
// as tabs when there are both. Below the replies: the reaction picker and reply composer
// (with the emoji button), or "You can't reply…" once you've left the group.
//
// Upstream's FocusScope focuses the first tabbable element on open: the first tab, else the
// first reply's message (`:focus-visible` paints it gray-65), else the picker's first
// reaction; with none, the modal itself shows Chromium's focus outline.
//
// Differences: the tabs scroll with the content instead of sticking to the top; the
// confirm-discard dialog is not shown; avatar badges are not drawn.

import AppKit
import SignalI18n
import SwiftUI

/// `ReplyType`: a reply to a group story, or a reaction to it (`reactionEmoji`).
public struct StoryReply: Sendable, Identifiable {
    public var id: String
    public var author: MessageProps.Author
    public var conversationId: String
    public var body: String?
    public var bodyRanges: [BodyRange] = []
    public var reactionEmoji: String?
    public var deletedForEveryone = false
    public var contactNameColor: String?
    public var timestamp: Date

    public init(id: String, author: MessageProps.Author, conversationId: String, body: String? = nil, reactionEmoji: String? = nil,
                timestamp: Date) {
        self.id = id
        self.author = author
        self.conversationId = conversationId
        self.body = body
        self.reactionEmoji = reactionEmoji
        self.timestamp = timestamp
    }
}

/// `StoryViewTargetType`
public enum StoryViewTarget: Sendable, Hashable { case views, replies }

public struct StoryViewsNRepliesActions {
    public var onClose: () -> Void = {}
    public var onReact: (String) -> Void = { _ in }
    public var onReply: (String) -> Void = { _ in }
    public var deleteGroupStoryReply: (String) -> Void = { _ in }
    public var deleteGroupStoryReplyForEveryone: (String) -> Void = { _ in }
    public var onChangeViewTarget: (StoryViewTarget) -> Void = { _ in }
    public init() {}
}

public struct StoryViewsNRepliesModal: View {
    let authorTitle: String
    let canReply: Bool
    /// nil: a 1:1 story; `left`: we are no longer in the group.
    let group: (left: Bool, Void)?
    let hasViewReceiptSetting: Bool
    let hasViewsCapability: Bool
    let isInternalUser: Bool
    let preferredReactionEmoji: [String]
    let replies: [StoryReply]
    let views: [StoryDetailsRecipient]
    let actions: StoryViewsNRepliesActions
    @State private var viewTarget: StoryViewTarget
    @State private var messageBodyText = ""
    @State private var emojiPickerOpen = false
    @State private var deleteReplyId: String?
    @State private var deleteForEveryoneReplyId: String?
    @Environment(\.i18n) var i18n
    @Environment(\.legacyModalMaxHeight) var hostMaxHeight

    public init(authorTitle: String, canReply: Bool, isGroup: Bool = false, groupLeft: Bool = false, hasViewReceiptSetting: Bool,
                hasViewsCapability: Bool, isInternalUser: Bool = false, preferredReactionEmoji: [String] = ReactionEmoji.defaultPreferred,
                replies: [StoryReply], views: [StoryDetailsRecipient], viewTarget: StoryViewTarget = .views,
                actions: StoryViewsNRepliesActions = StoryViewsNRepliesActions()) {
        self.authorTitle = authorTitle
        self.canReply = canReply
        self.group = isGroup ? (groupLeft, ()) : nil
        self.hasViewReceiptSetting = hasViewReceiptSetting
        self.hasViewsCapability = hasViewsCapability
        self.isInternalUser = isInternalUser
        self.preferredReactionEmoji = preferredReactionEmoji
        self.replies = replies
        self.views = views
        self.actions = actions
        _viewTarget = State(initialValue: viewTarget)
    }

    enum ViewsElement { case readReceiptsOff, list, noViews }

    var viewsElement: ViewsElement? {
        if hasViewsCapability && !hasViewReceiptSetting { return .readReceiptsOff }
        if !views.isEmpty { return .list }
        if hasViewsCapability { return .noViews }
        return nil
    }

    /// `repliesElement`: the list, "No replies yet" in a group, else nothing.
    var hasRepliesElement: Bool { !replies.isEmpty || group != nil }
    var composerKind: ComposerKind? {
        if let group, group.left { return .notAMember }
        return canReply ? .composer : nil
    }

    enum ComposerKind { case notAMember, composer }

    var hasTabs: Bool { viewsElement != nil && hasRepliesElement }
    var isEmpty: Bool { viewsElement == nil && !hasRepliesElement && composerKind == nil }

    /// FocusScope autoFocus: the first tabbable element.
    enum AutoFocus { case firstTab, firstReply, reaction, modal }
    var autoFocus: AutoFocus {
        if hasTabs { return .firstTab }
        let showsReplies = viewsElement == nil
        if showsReplies && replies.contains(where: { $0.reactionEmoji == nil || $0.deletedForEveryone }) { return .firstReply }
        if (showsReplies || viewsElement != nil) && composerKind == .composer && (viewsElement == nil) { return .reaction }
        return .modal
    }

    public var body: some View {
        if isEmpty {
            EmptyView()
        } else {
            ModalHost(onClose: actions.onClose, alignment: .bottomTrailing) {
                ModalPage(modalName: "StoryViewsNRepliesModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")),
                          padded: false, onClose: actions.onClose) {
                    content
                }
                .contentTakesFocus(autoFocus != .modal)
                .frame(minWidth: 320)
                // max-height: 80vh (the host gives 89vh).
                .environment(\.legacyModalMaxHeight, hostMaxHeight / 0.89 * 0.8)
                .environment(\.colorScheme, .dark)
            }
            .overlay { deleteDialogs }
        }
    }

    /// `__content`: 16px padding (no top padding above the tabs); in a group a flex column at
    /// least min(400px, 80vh) − nothing else tall.
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasTabs {
                StoryViewsNRepliesTabs(selected: $viewTarget, labels: [i18n("icu:StoryViewsNRepliesModal__tab--views"),
                                                                       i18n("icu:StoryViewsNRepliesModal__tab--replies")],
                                       autoFocus: autoFocus == .firstTab) { actions.onChangeViewTarget($0) }
                if viewTarget == .views {
                    viewsSection
                } else {
                    repliesSection
                    composer
                }
            } else {
                if viewsElement != nil { viewsSection } else { repliesSection }
                composer
            }
        }
        .padding(.top, hasTabs ? 0 : 16)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
        .frame(minHeight: group != nil ? min(400, hostMaxHeight / 0.89 * 0.8) : nil, alignment: .top)
    }

    var gray25: AxoColor { AxoColor(LegacyColor.gray25) }
    var gray45: AxoColor { AxoColor(LegacyColor.gray45) }

    @ViewBuilder var viewsSection: some View {
        switch viewsElement {
        case .readReceiptsOff:
            CSSBlockText(i18n("icu:StoryViewsNRepliesModal__read-receipts-off"), style: LegacyType.body1(), color: gray25)
                .padding(.vertical, 160).padding(.horizontal, 16)
        case .list:
            // orderBy(views, 'updatedAt', 'desc'); each row margin-block 8px (collapsing).
            let sorted = views.enumerated().sorted { a, b in
                let ta = a.element.updatedAt ?? .distantPast, tb = b.element.updatedAt ?? .distantPast
                return ta == tb ? a.offset < b.offset : ta > tb
            }.map(\.element)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sorted) { view in viewRow(view) }
            }
            .padding(.vertical, 8)
        case .noViews:
            noneText(i18n("icu:StoryViewsNRepliesModal__no-views"))
        case nil:
            EmptyView()
        }
    }

    func viewRow(_ view: StoryDetailsRecipient) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: view.title, size: 28, conversationType: .direct, color: view.color,
                   image: view.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
            ContactName(title: view.title, style: LegacyType.body2())
                .padding(.leading, 12)
            Spacer(minLength: 0)
            if let updatedAt = view.updatedAt {
                MessageTimestamp(timestamp: updatedAt, style: LegacyType.body2(), color: gray45)
            }
        }
    }

    /// `__replies--none`: gray-45, centred in the remaining height, 80px above and below.
    func noneText(_ text: String) -> some View {
        CSSText(text, style: LegacyType.body1(), wrap: .wrap, color: gray45)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder var repliesSection: some View {
        if !replies.isEmpty {
            // `__replies`: flex 1, margin-inline −16px (the messages bring their own 16px).
            VStack(alignment: .leading, spacing: 0) {
                let firstMessage = replies.firstIndex { $0.reactionEmoji == nil || $0.deletedForEveryone }
                ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                    replyRow(reply, index: index, focused: autoFocus == .firstReply && index == firstMessage)
                }
            }
            .padding(.horizontal, -16)
            .frame(maxHeight: .infinity, alignment: .top)
        } else if group != nil {
            noneText(i18n("icu:StoryViewsNRepliesModal__no-replies"))
        }
    }

    /// Reactions (and deleted replies) above / below a reply from the same sender join it.
    static func shouldCollapse(_ reply: StoryReply, _ other: StoryReply?) -> Bool {
        guard let other else { return false }
        return reply.conversationId == other.conversationId && (other.reactionEmoji == nil || other.deletedForEveryone)
    }

    @ViewBuilder func replyRow(_ reply: StoryReply, index: Int, focused: Bool) -> some View {
        if let emoji = reply.reactionEmoji, !reply.deletedForEveryone {
            reactionRow(reply, emoji: emoji)
                .contextMenu { replyMenu(reply) }
        } else {
            var props = MessageProps(id: reply.id, direction: .incoming, author: reply.author, text: reply.body, timestamp: reply.timestamp)
            let _ = {
                props.conversationType = .group
                props.bodyRanges = reply.bodyRanges
                props.contactNameColor = reply.contactNameColor
                props.deletedForEveryone = reply.deletedForEveryone
                props.conversationTitle = reply.author.title
                props.shouldCollapseAbove = Self.shouldCollapse(reply, index > 0 ? replies[index - 1] : nil)
                props.shouldCollapseBelow = Self.shouldCollapse(reply, index + 1 < replies.count ? replies[index + 1] : nil)
            }()
            // `__reply`: flex-end, 12px below.
            StoryReplyMessage(props: props, autoFocus: focused)
                .contextMenu { replyMenu(reply) }
                .padding(.bottom, 12)
        }
    }

    /// `__reaction`: avatar, name, "Reacted to the story" + relative time, the emoji at the end.
    func reactionRow(_ reply: StoryReply, emoji: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Avatar(strings: AvatarStrings(i18n: i18n), title: reply.author.title, size: 28, conversationType: .direct,
                       color: reply.author.color ?? "A200", image: reply.author.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
                VStack(alignment: .leading, spacing: 0) {
                    ContactName(title: reply.author.isMe ? i18n("icu:you") : reply.author.title, contactNameColor: reply.contactNameColor,
                                style: LegacyType.body2())
                    let text = reply.author.isMe ? i18n("icu:StoryViewsNRepliesModal__reacted--you")
                        : i18n("icu:StoryViewsNRepliesModal__reacted--someone-else")
                    CSSInlineTail(text, style: LegacyType.body1()) {
                        MessageTimestamp(timestamp: reply.timestamp, isRelativeTime: true, style: LegacyType.subtitle(), color: gray25)
                            .padding(.leading, 6)
                    }
                }
                .padding(.leading, 20)
            }
            Spacer(minLength: 0)
            FunStaticEmoji(emoji, size: 20)
                .frame(width: 20, height: 20)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    @ViewBuilder func replyMenu(_ reply: StoryReply) -> some View {
        Button(i18n("icu:StoryViewsNRepliesModal__delete-reply")) { deleteReplyId = reply.id }
        if !reply.deletedForEveryone {
            Button(i18n("icu:StoryViewsNRepliesModal__delete-reply-for-everyone")) { deleteForEveryoneReplyId = reply.id }
        }
        if isInternalUser {
            Button(i18n("icu:StoryViewsNRepliesModal__copy-reply-timestamp")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(String(Int64(reply.timestamp.timeIntervalSince1970 * 1000)), forType: .string)
            }
        }
    }

    @ViewBuilder var composer: some View {
        switch composerKind {
        case .notAMember:
            CSSBlockText(i18n("icu:StoryViewsNRepliesModal__not-a-member"), style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 12, lineHeight: 20),
                         alignment: .center, color: gray25)
                .frame(maxWidth: .infinity)
                .padding(.top, 24).padding(.bottom, 8).padding(.horizontal, 4)
        case .composer:
            VStack(spacing: 0) {
                ReactionPicker(preferredReactionEmoji: preferredReactionEmoji, autoFocus: autoFocus == .reaction) { emoji in
                    actions.onReact(emoji)
                    if group == nil && messageBodyText.isEmpty { actions.onClose() }
                }
                .embedded()
                .environment(\.colorScheme, .dark)
                // An inline-flex box on its own line: the line box (strut, 20px line height)
                // reaches 6px below the picker, whose baseline is its emoji's.
                .padding(.bottom, group == nil ? 6 : 0)      // (in a group the column blockifies it)
                CompositionInput(text: $messageBodyText,
                                 placeholder: group != nil ? i18n("icu:StoryViewer__reply-group")
                                     : i18n("icu:StoryViewer__reply-placeholder", ["firstName": .string(authorTitle)]),
                                 isActive: true, onSubmit: {
                                     actions.onReply(messageBodyText)
                                     messageBodyText = ""
                                 }, variant: .storyReply)
                    .leading(FunEmojiPickerButton(isOpen: $emojiPickerOpen))
                    .padding(.top, 6)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder var deleteDialogs: some View {
        if let id = deleteReplyId {
            AxoConfirmDialog.Root(title: i18n("icu:deleteWarning"), description: nil) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { deleteReplyId = nil }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    deleteReplyId = nil
                    actions.deleteGroupStoryReply(id)
                }
            }
        } else if let id = deleteForEveryoneReplyId {
            AxoConfirmDialog.Root(title: i18n("icu:deleteWarning"), description: i18n("icu:deleteForEveryoneWarning")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { deleteForEveryoneReplyId = nil }
                AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive) {
                    deleteForEveryoneReplyId = nil
                    actions.deleteGroupStoryReplyForEveryone(id)
                }
            }
        }
    }
}

/// A reply's Message, shrink-wrapped; while it has the initial keyboard focus,
/// `.module-message:focus-visible` paints it with the selected-message background.
struct StoryReplyMessage: View {
    let props: MessageProps
    let autoFocus: Bool
    private var focus = AxoFocusState()

    init(props: MessageProps, autoFocus: Bool) {
        self.props = props
        self.autoFocus = autoFocus
    }

    var body: some View {
        Message(props: props)
            .environment(\.messageShrinkWrapped, true)
            .fixedSize(horizontal: true, vertical: false)
            .background(focus.visible(autoFocus: autoFocus) ? AxoColor(light: LegacyColor.selectedMessageBackgroundLight,
                                                                       dark: LegacyColor.selectedMessageBackgroundDark)
                                                            : AxoColor(RGBA(0, 0, 0, 0)))
            .focusable()
            .focusEffectDisabled()
            .focused(focus.$focused)
            .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.Tabs.StoryViewsNRepliesModal__tabs`: centred pills (body-1 bold, 4px × 12px padding, 12px
/// apart from the edges of their 12px margins) on gray-80, 16px above and below; the selected
/// one gray-65 and fully rounded. Unselected tabs keep a 4px transparent bottom border, so
/// every tab's text sits 4px from its top.
struct StoryViewsNRepliesTabs: View {
    @Binding var selected: StoryViewTarget
    let labels: [String]
    let autoFocus: Bool
    let onChange: (StoryViewTarget) -> Void

    var body: some View {
        HStack(spacing: 24) {
            tab(.views, labels[0], first: true)
            tab(.replies, labels[1], first: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(rgba: LegacyColor.gray80))
    }

    func tab(_ target: StoryViewTarget, _ label: String, first: Bool) -> some View {
        StoryViewsNRepliesTab(label: label, isSelected: selected == target, autoFocus: autoFocus && first) {
            selected = target
            onChange(target)
        }
    }
}

struct StoryViewsNRepliesTab: View {
    let label: String
    let isSelected: Bool
    let autoFocus: Bool
    let action: () -> Void
    private var focus = AxoFocusState()

    init(label: String, isSelected: Bool, autoFocus: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.autoFocus = autoFocus
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        Button(action: action) {
            CSSText(label, style: LegacyType.body1(weight: 600), wrap: .nowrap)
                .padding(.vertical, 4).padding(.horizontal, 12)
                .frame(height: 32, alignment: .top)
                .background { if isSelected { shape.fill(Color(rgba: LegacyColor.gray65)) } }
                .contentShape(shape)
        }
        .buttonStyle(UndimmedButtonStyle())
        .axoFocusRing(focus.visible(autoFocus: autoFocus), in: shape)
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
