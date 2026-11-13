// TimelineMessage (ts/components/conversation/TimelineMessage.dom.tsx, MessageContextMenu.dom.tsx
// and `.module-message__buttons*` in _modules.scss): a timeline message's actions — the
// buttons beside the bubble while the row is hovered (react, download, reply and the ⋯ menu;
// 20px gray-45 icons 12px apart, 8px from the bubble), the same menu on right-click of the
// bubble, the reaction picker above the react button (its ⋯ opens the emoji picker), and
// double-click to reply. `Message` renders them when `MessageProps.actions` is set.

import SignalI18n
import SwiftUI

/// The actions of a timeline message; nil: not offered (upstream's `can…` false).
public struct TimelineMessageActions {
    /// `reactToMessage(emoji, remove)`
    public var react: ((String, Bool) -> Void)?
    /// `selectedReaction`: our current reaction (picking it again removes it).
    public var selectedReaction: String?
    /// The emoji already reacted with (the emoji picker's "in this message" row).
    public var messageEmojis: [String] = []
    public var preferredReactions: [String] = ReactionEmoji.defaultPreferred
    public var recentEmojis: [String] = []
    /// `onUseEmoji`: an emoji picked in the emoji picker (its recents); the quick reactions are not counted.
    public var useEmoji: ((String) -> Void)?
    /// The default emoji skin tone (nil: not chosen yet), and where a choice goes.
    public var skinTone: EmojiSkinTone?
    public var setSkinTone: ((EmojiSkinTone) -> Void)?
    public var reply: (() -> Void)?
    public var download: (() -> Void)?
    public var edit: (() -> Void)?
    public var endPoll: (() -> Void)?
    public var forward: (() -> Void)?
    public var select: (() -> Void)?
    public var copy: (() -> Void)?
    public var pin: (() -> Void)?
    public var unpin: (() -> Void)?
    public var moreInfo: (() -> Void)?
    public var delete: (() -> Void)?
    public var retrySend: (() -> Void)?
    public var retryDeleteForEveryone: (() -> Void)?

    public init() {}

    /// One menu item.
    public struct Entry {
        public var title: String
        public var symbol: AxoSymbol.Name
        public var action: () -> Void
    }

    /// MessageContextMenu's items in order. `shouldShowAdditional` (the body overflows, or the
    /// timeline is narrow) adds download, reply and react, which the buttons otherwise offer.
    @MainActor
    public func entries(_ i18n: Localizer, shouldShowAdditional: Bool, openReactionPicker: @escaping () -> Void) -> [Entry] {
        var out: [Entry] = []
        if shouldShowAdditional {
            if let download { out.append(Entry(title: i18n("icu:MessageContextMenu__download"), symbol: "download", action: download)) }
            if let reply { out.append(Entry(title: i18n("icu:MessageContextMenu__reply"), symbol: "reply", action: reply)) }
            if react != nil { out.append(Entry(title: i18n("icu:MessageContextMenu__react"), symbol: "heart-plus", action: openReactionPicker)) }
        }
        if let endPoll { out.append(Entry(title: i18n("icu:Poll__end-poll"), symbol: "stop-circle", action: endPoll)) }
        if let forward { out.append(Entry(title: i18n("icu:MessageContextMenu__forward"), symbol: "forward", action: forward)) }
        if let edit { out.append(Entry(title: i18n("icu:edit"), symbol: "pencil", action: edit)) }
        if let select { out.append(Entry(title: i18n("icu:MessageContextMenu__select"), symbol: "check-circle", action: select)) }
        if let copy { out.append(Entry(title: i18n("icu:copy"), symbol: "copy", action: copy)) }
        if let pin { out.append(Entry(title: i18n("icu:MessageContextMenu__PinMessage"), symbol: "pin", action: pin)) }
        if let unpin { out.append(Entry(title: i18n("icu:MessageContextMenu__UnpinMessage"), symbol: "pin-slash", action: unpin)) }
        if let moreInfo { out.append(Entry(title: i18n("icu:MessageContextMenu__info"), symbol: "info-circle", action: moreInfo)) }
        if let delete { out.append(Entry(title: i18n("icu:MessageContextMenu__deleteMessage"), symbol: "trash", action: delete)) }
        if let retrySend { out.append(Entry(title: i18n("icu:retrySend"), symbol: "send", action: retrySend)) }
        if let retryDeleteForEveryone {
            out.append(Entry(title: i18n("icu:retryDeleteForEveryone"), symbol: "trash", action: retryDeleteForEveryone))
        }
        return out
    }
}

/// The menu's items (dropdown or context menu).
struct MessageContextMenuItems: View {
    let entries: [TimelineMessageActions.Entry]
    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            AxoDropdownMenu.Item(e.title, symbol: e.symbol, action: e.action)
        }
    }
}

/// The open popovers and menus of one message (they keep the buttons visible).
struct MessageMenuState: Equatable {
    var reactionPicker = false
    var emojiPicker = false
    var dropdown = false
    var contextMenu: CGPoint?
    var anyOpen: Bool { reactionPicker || emojiPicker || dropdown || contextMenu != nil }
}

/// `MessageMenu`: `.module-message__buttons` (incoming: react, download, reply, menu; outgoing
/// the reverse, so the menu is outermost on both sides).
struct MessageMenuButtons: View {
    let direction: MessageDirection
    let actions: TimelineMessageActions
    let entries: [TimelineMessageActions.Entry]
    @Binding var state: MessageMenuState
    @State private var pickerId = UUID().uuidString
    @State private var emojiId = UUID().uuidString
    @Environment(\.i18n) var i18n

    var body: some View {
        HStack(spacing: 12) {
            if direction == .incoming { ordered } else { reversed }
        }
    }

    @ViewBuilder var ordered: some View {
        react
        download
        reply
        menu
    }

    @ViewBuilder var reversed: some View {
        menu
        reply
        download
        react
    }

    @ViewBuilder var react: some View {
        if actions.react != nil {
            MessageMenuButton(icon: "v3/heart/heart-plus", label: i18n("icu:reactToMessage")) { state.reactionPicker.toggle() }
                .axoPopper(id: pickerId, isPresented: state.reactionPicker,
                           placement: AxoPopper.Placement(side: .top, align: .center, sideOffset: 4, collisionPadding: 8),
                           dismiss: { state.reactionPicker = false }) {
                    ReactionPicker(preferredReactionEmoji: actions.preferredReactions, selected: actions.selectedReaction, onPick: pick,
                                   onMore: { state.reactionPicker = false; state.emojiPicker = true }, onClose: { state.reactionPicker = false })
                }
                .axoPopper(id: emojiId, isPresented: state.emojiPicker,
                           placement: AxoPopper.Placement(side: .top, align: .center, sideOffset: 4, collisionPadding: 8),
                           dismiss: { state.emojiPicker = false }) {
                    FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: actions.recentEmojis, messageEmojis: actions.messageEmojis,
                                                         skinTone: actions.skinTone, onSelectEmoji: { actions.useEmoji?($0); pick($0) },
                                                         onSelectSkinTone: { actions.setSkinTone?($0) }))
                }
        }
    }

    func pick(_ emoji: String) {
        state.reactionPicker = false
        state.emojiPicker = false
        actions.react?(emoji, emoji == actions.selectedReaction)
    }

    @ViewBuilder var download: some View {
        if let d = actions.download { MessageMenuButton(icon: "v3/save/save", label: i18n("icu:downloadAttachment"), action: d) }
    }

    @ViewBuilder var reply: some View {
        if let r = actions.reply { MessageMenuButton(icon: "v3/reply/reply", label: i18n("icu:replyToMessage"), action: r) }
    }

    var menu: some View {
        AxoDropdownMenu.Root(isOpen: $state.dropdown) {
            MessageMenuButton(icon: "v3/more/more", label: i18n("icu:messageContextMenuButton"), active: state.dropdown) {}
        } items: {
            MessageContextMenuItems(entries: entries)
        }
    }
}

/// `module-message__buttons__button`: a 20px icon, gray-45; hovered gray-90 (dark gray-02).
struct MessageMenuButton: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        SwiftUI.Button(action: action) {
            SignalIcon(icon, size: 20, color: hovered || active ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray02) : AxoColor(LegacyColor.gray45))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// SelectModeActions (ts/components/conversation/SelectModeActions.dom.tsx): in place of the
/// composer while selecting — exit, "N selected", delete, forward (at most 30 messages).
public struct SelectModeActions: View {
    /// MAX_FORWARD_COUNT (kept in sync with iOS and Android).
    public static let maxForwardCount = 30
    let selectedCount: Int
    let areSelectedMessagesForwardable: Bool
    let onExitSelectMode: () -> Void
    let onDeleteMessages: () -> Void
    let onForwardMessages: () -> Void
    let showTooManyToast: () -> Void
    @Environment(\.i18n) var i18n

    public init(selectedCount: Int, areSelectedMessagesForwardable: Bool, onExitSelectMode: @escaping () -> Void,
                onDeleteMessages: @escaping () -> Void, onForwardMessages: @escaping () -> Void, showTooManyToast: @escaping () -> Void = {}) {
        self.selectedCount = selectedCount
        self.areSelectedMessagesForwardable = areSelectedMessagesForwardable
        self.onExitSelectMode = onExitSelectMode
        self.onDeleteMessages = onDeleteMessages
        self.onForwardMessages = onForwardMessages
        self.showTooManyToast = showTooManyToast
    }

    var tooMany: Bool { selectedCount > Self.maxForwardCount }
    var canForward: Bool { selectedCount >= 1 && areSelectedMessagesForwardable && !tooMany }
    var canDelete: Bool { selectedCount >= 1 }

    public var body: some View {
        HStack(spacing: 0) {
            button("v3/x/x", i18n("icu:SelectModeActions--exitSelectMode"), enabled: true, action: onExitSelectMode)
            CSSText(i18n("icu:SelectModeActions--selectedMessages", ["count": .number(Double(selectedCount))]), style: LegacyType.body1(),
                    color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                .padding(.vertical, 17).padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            button("v3/trash/trash", i18n("icu:SelectModeActions--deleteSelectedMessages"), enabled: canDelete) { if canDelete { onDeleteMessages() } }
            button("v3/forward/forward", i18n("icu:SelectModeActions--forwardSelectedMessages"), enabled: canForward) {
                if canForward { onForwardMessages() } else if tooMany { showTooManyToast() }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
    }

    func button(_ icon: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            SignalIcon(icon, size: 20, color: enabled ? AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15)
                                                      : AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60))
                .padding(12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension EnvironmentValues {
    /// Tests: the hover buttons shown without hovering.
    @Entry var messageMenuAlwaysVisible = false
}
