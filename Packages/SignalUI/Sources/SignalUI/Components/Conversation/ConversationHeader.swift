// ConversationHeader (ts/components/conversation/ConversationHeader.dom.tsx + stylesheets/
// components/ConversationHeader.scss): the 52px bar over the timeline — the 32px avatar
// (story ring, opens stories or details), the title (body-1-bold, in-contacts icon, official
// badge) and subtitle (official chat · disappearing timer · verified), then the call buttons,
// mute (Signal's chat), search and the overflow menu, on an elevation-1 shadow (no outline).
// Below: the name-collision warning (TimelineWarning), then the mini player or the pinned
// messages bar.
//
// The dialogs the menu opens (disappearing-time picker, delete / leave confirmations,
// message-request confirmations) are presented by the caller through the actions.

import SignalI18n
import SwiftUI

/// `MinimalConversation`: the fields the header reads.
public struct ConversationHeaderModel: Sendable {
    public enum Kind: Sendable { case direct, group }
    public var id: String
    public var type: Kind
    public var title: String
    /// The system-contact name (`isInSystemContacts`).
    public var name: String?
    public var isMe = false
    public var color: String?
    public var avatar: RGBAImage?
    public var hasAvatar = false
    public var expireTimer: Int?
    public var isVerified = false
    public var isMuted = false
    public var groupVersion: Int = 2
    public var announcementsOnly = false
    public var areWeAdmin = false
    public var terminated = false
    public var left = false
    public var acceptedMessageRequest = true
    public var isBlocked = false
    public var isArchived = false
    public var isPinned = false
    public var markedUnread = false
    public var canChangeTimer = true

    public init(id: String, type: Kind, title: String) {
        self.id = id
        self.type = type
        self.title = title
    }
}

/// `OutgoingCallButtonStyle`
public enum OutgoingCallButtonStyle: Sendable { case none, justVideo, both, join }

/// The header's actions (upstream PropsActionsType).
public struct ConversationHeaderActions {
    public var onOutgoingAudioCall: () -> Void = {}
    public var onOutgoingVideoCall: () -> Void = {}
    public var onSearchInConversation: () -> Void = {}
    public var onViewConversationDetails: () -> Void = {}
    public var onViewUserStories: () -> Void = {}
    public var onMuteExpirationChange: (MuteOption?) -> Void = { _ in }
    public var onDisappearingMessagesChange: (Int) -> Void = { _ in }
    public var onSetupCustomDisappearingTimeout: () -> Void = {}
    public var onAccept: () -> Void = {}
    public var onBlock: () -> Void = {}
    public var onUnblock: () -> Void = {}
    public var onReportSpam: () -> Void = {}
    public var onDelete: () -> Void = {}
    public var onDeleteMessages: () -> Void = {}
    public var onLeaveGroup: () -> Void = {}
    public var onArchive: () -> Void = {}
    public var onUnarchive: () -> Void = {}
    public var onPin: () -> Void = {}
    public var onUnpin: () -> Void = {}
    public var onMarkUnread: () -> Void = {}
    public var onSelectModeEnter: () -> Void = {}
    public var onShowMembers: () -> Void = {}
    public var onViewAllMedia: () -> Void = {}
    public var onReviewNameCollision: () -> Void = {}
    public var onAcknowledgeNameCollisions: () -> Void = {}
    public init() {}
}

/// `ContactSpoofingWarning` as the header shows it.
public enum ContactSpoofingWarning: Sendable, Hashable {
    case directConversationWithSameTitle
    /// Unacknowledged collisions: the number of shared names, and the members colliding.
    case multipleGroupMembersWithSameTitle(sharedNames: Int, conversationIds: [String])
}

public struct ConversationHeader<Subheader: View>: View {
    let conversation: ConversationHeaderModel
    let hasStories: HasStories?
    let hasActiveCall: Bool
    let isSelectMode: Bool
    let isSignalConversation: Bool
    let isSmsOnlyOrUnregistered: Bool
    let isMissingMandatoryProfileSharing: Bool
    let hasPanelShowing: Bool
    let outgoingCallButtonStyle: OutgoingCallButtonStyle
    let contactSpoofingWarning: ContactSpoofingWarning?
    let collidingAvatars: [ConversationAvatarData]
    let actions: ConversationHeaderActions
    /// The mini player (when shown) or the pinned messages bar.
    let subheader: Subheader
    @State private var menuOpen = false
    @State private var dismissedDirectWarning = false
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme

    public init(conversation: ConversationHeaderModel, hasStories: HasStories? = nil, hasActiveCall: Bool = false, isSelectMode: Bool = false,
                isSignalConversation: Bool = false, isSmsOnlyOrUnregistered: Bool = false, isMissingMandatoryProfileSharing: Bool = false,
                hasPanelShowing: Bool = false, outgoingCallButtonStyle: OutgoingCallButtonStyle, contactSpoofingWarning: ContactSpoofingWarning? = nil,
                collidingAvatars: [ConversationAvatarData] = [], actions: ConversationHeaderActions = ConversationHeaderActions(),
                @ViewBuilder subheader: () -> Subheader) {
        self.conversation = conversation
        self.hasStories = hasStories
        self.hasActiveCall = hasActiveCall
        self.isSelectMode = isSelectMode
        self.isSignalConversation = isSignalConversation
        self.isSmsOnlyOrUnregistered = isSmsOnlyOrUnregistered
        self.isMissingMandatoryProfileSharing = isMissingMandatoryProfileSharing
        self.hasPanelShowing = hasPanelShowing
        self.outgoingCallButtonStyle = outgoingCallButtonStyle
        self.contactSpoofingWarning = contactSpoofingWarning
        self.collidingAvatars = collidingAvatars
        self.actions = actions
        self.subheader = subheader()
    }

    public var body: some View {
        if !hasPanelShowing {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HeaderContent(conversation: conversation, hasStories: hasStories, isSignalConversation: isSignalConversation,
                                  onViewUserStories: actions.onViewUserStories, onViewConversationDetails: actions.onViewConversationDetails)
                    buttons
                }
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                if let warning = renderableWarning { warningView(warning) }
                subheader
            }
            .background(AxoColor.surfacePrimary)
            .cssBoxShadow(AxoShadow.baseShadowElevation1.layers(scheme), in: Rectangle())
        }
    }

    var renderableWarning: ContactSpoofingWarning? {
        switch contactSpoofingWarning {
        case .directConversationWithSameTitle: dismissedDirectWarning ? nil : contactSpoofingWarning
        default: contactSpoofingWarning
        }
    }

    @ViewBuilder func warningView(_ warning: ContactSpoofingWarning) -> some View {
        let link = I18nTagStyle(fontName: AxoFonts.interName(weight: 700), color: AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.iosBlueTint),
                                action: "review")
        switch warning {
        case .directConversationWithSameTitle:
            TimelineWarning(onClose: { dismissedDirectWarning = true }, onLink: actions.onReviewNameCollision,
                            text: CSSTextRun.runs(i18n.richText("icu:ContactSpoofing__same-name--link"), tags: ["reviewRequestLink": link])) { EmptyView() }
        case .multipleGroupMembersWithSameTitle(let sharedNames, let ids):
            if sharedNames == 1 {
                TimelineWarning(onClose: actions.onAcknowledgeNameCollisions, onLink: actions.onReviewNameCollision,
                                text: CSSTextRun.runs(i18n.richText("icu:ContactSpoofing__same-name-in-group--link", ["count": .number(Double(ids.count))]),
                                                      tags: ["reviewRequestLink": link])) {
                    if ids.count >= 2 { CollidingAvatars(conversations: collidingAvatars) }
                }
            } else {
                TimelineWarning(onClose: actions.onAcknowledgeNameCollisions, onLink: actions.onReviewNameCollision,
                                text: CSSTextRun.runs(i18n.richText("icu:ContactSpoofing__same-names-in-group--link", ["count": .number(Double(sharedNames))]),
                                                      tags: ["reviewRequestLink": link])) { EmptyView() }
            }
        }
    }

    /// `flex flex-row gap-1 px-4 @min-[500px]:gap-3`
    var buttons: some View {
        ViewThatFits(in: .horizontal) {
            buttonRow(gap: 12)
            buttonRow(gap: 4)
        }
    }

    func buttonRow(gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            if !isSmsOnlyOrUnregistered && !isSignalConversation && !conversation.terminated {
                OutgoingCallButtons(conversation: conversation, hasActiveCall: hasActiveCall, style: outgoingCallButtonStyle,
                                    onOutgoingAudioCall: actions.onOutgoingAudioCall, onOutgoingVideoCall: actions.onOutgoingVideoCall)
            }
            if isSignalConversation {
                AxoIconButton.Root(label: i18n(conversation.isMuted ? "icu:unmute" : "icu:mute"), variant: .impliedSecondary, size: .md,
                                   symbol: conversation.isMuted ? "bell-slash" : "bell") {
                    actions.onMuteExpirationChange(conversation.isMuted ? nil : .always)
                }
            }
            AxoIconButton.Root(label: i18n("icu:search"), variant: .impliedSecondary, size: .md, symbol: "search", action: actions.onSearchInConversation)
            AxoDropdownMenu.Root(isOpen: $menuOpen) {
                AxoIconButton.Root(label: i18n("icu:moreInfo"), variant: .impliedSecondary, size: .md, symbol: "more")
                    .disabled(isSelectMode)
            } items: {
                ConversationHeaderMenu(conversation: conversation, isSignalConversation: isSignalConversation,
                                       isMissingMandatoryProfileSharing: isMissingMandatoryProfileSharing, actions: actions)
            }
        }
        .padding(.horizontal, 16)
        .fixedSize()
    }
}

extension ConversationHeader where Subheader == EmptyView {
    public init(conversation: ConversationHeaderModel, outgoingCallButtonStyle: OutgoingCallButtonStyle,
                actions: ConversationHeaderActions = ConversationHeaderActions()) {
        self.init(conversation: conversation, outgoingCallButtonStyle: outgoingCallButtonStyle, actions: actions) { EmptyView() }
    }
}

/// `HeaderContent`: `.module-ConversationHeader__header` (margin 0 4px, padding 4px 12px; the
/// clickable part's start padding 0).
struct HeaderContent: View {
    let conversation: ConversationHeaderModel
    let hasStories: HasStories?
    let isSignalConversation: Bool
    let onViewUserStories: () -> Void
    let onViewConversationDetails: () -> Void
    @Environment(\.i18n) var i18n

    var onClick: (() -> Void)? {
        conversation.type == .direct || conversation.groupVersion == 2 ? onViewConversationDetails : nil
    }

    var isOfficialChat: Bool { isSignalConversation || conversation.isMe }

    var body: some View {
        HStack(spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: conversation.title, size: 32,
                   conversationType: conversation.type == .group ? .group : .direct, color: conversation.color ?? "A200",
                   image: conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: conversation.hasAvatar,
                   noteToSelf: conversation.isMe, storyRing: conversation.isMe ? nil : hasStories,
                   onClick: hasStories != nil ? onViewUserStories : onClick)
                .padding(.vertical, 4)
                .padding(.trailing, 12)
            if let onClick {
                SwiftUI.Button(action: onClick) { info }
                    .buttonStyle(.plain)
                    .padding(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 12))
                    .padding(.horizontal, 4)
            } else {
                info
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .padding(.horizontal, 4)
    }

    var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            if isOfficialChat || (conversation.expireTimer ?? 0) != 0 || conversation.isVerified {
                // __subtitle: body-2, gray-60 / gray-25, 12px gap
                HStack(spacing: 12) {
                    if isOfficialChat { CSSText(i18n("icu:ConversationHero--signal-official-chat-title"), style: LegacyType.body2(), wrap: .nowrap) }
                    if let timer = conversation.expireTimer, timer != 0 {
                        iconElement("v3/timer/timer-compact", ExpirationTimer.format(i18n, timer)).padding(.trailing, 12)
                    }
                    if !isOfficialChat && conversation.isVerified { iconElement("v3/safety_number/safety_number-compact", i18n("icu:verified")) }
                }
                .cssTextColor(AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
            }
        }
    }

    /// `icon-element`: a 14px icon, 4px gap, text.
    func iconElement(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            SignalIcon(icon, size: 14, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
            CSSText(text, style: LegacyType.body2(), wrap: .truncate)
        }
    }

    /// `HeaderInfoTitle`: body-1-bold.
    @ViewBuilder var title: some View {
        let style = LegacyType.body1(weight: 600)
        HStack(spacing: 0) {
            if isSignalConversation || conversation.isMe {
                CSSText(runs: [Emojify.run(conversation.isMe ? i18n("icu:noteToSelf") : conversation.title), CSSTextRun("\u{00A0}")], style: style,
                        wrap: .truncate)
                OfficialChatInlineBadge(size: style.size, weight: style.weight)
            } else {
                CSSText(runs: [Emojify.run(conversation.title)], style: style, wrap: .truncate)
                if conversation.type == .direct, let name = conversation.name, !name.isEmpty {
                    InContactsIcon().padding(.horizontal, 2).padding(.leading, 4).frame(height: 20)
                }
            }
        }
    }
}

/// `OutgoingCallButtons`
struct OutgoingCallButtons: View {
    let conversation: ConversationHeaderModel
    let hasActiveCall: Bool
    let style: OutgoingCallButtonStyle
    let onOutgoingAudioCall: () -> Void
    let onOutgoingVideoCall: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme

    var disabled: Bool { conversation.type == .group && ((conversation.announcementsOnly && !conversation.areWeAdmin) || conversation.terminated) }
    var inAnotherCall: Bool { !disabled && hasActiveCall }
    var dimmed: Double { scheme == .dark ? 0.4 : 0.5 }

    var body: some View {
        switch style {
        case .none: EmptyView()
        case .justVideo: video
        case .both:
            video
            AxoIconButton.Root(label: i18n("icu:makeOutgoingCall"), variant: .impliedSecondary, size: .md, symbol: "phone", action: onOutgoingAudioCall)
                .opacity(inAnotherCall ? dimmed : 1)
        case .join:
            ViewThatFits(in: .horizontal) {
                InAnotherCallTooltipView(inAnotherCall: inAnotherCall) {
                    AxoButton.Root(i18n("icu:joinOngoingCall"), variant: .strongAffirmative, size: .md, symbol: "videocamera-fill",
                                   discouraged: inAnotherCall, action: onOutgoingVideoCall)
                }
                AxoIconButton.Root(label: i18n("icu:joinOngoingCall"), variant: .strongAffirmative, size: .md, symbol: "videocamera-fill",
                                   action: onOutgoingVideoCall)
                    .opacity(inAnotherCall ? dimmed : 1)
            }
        }
    }

    var video: some View {
        AxoIconButton.Root(label: i18n("icu:makeOutgoingVideoCall"), variant: .impliedSecondary, size: .md, symbol: "videocamera",
                           action: onOutgoingVideoCall)
            .opacity(inAnotherCall || disabled ? dimmed : 1)
    }
}

/// InAnotherCallTooltip (ts/components/conversation/InAnotherCallTooltip.dom.tsx)
struct InAnotherCallTooltipView<Content: View>: View {
    let inAnotherCall: Bool
    @ViewBuilder let content: Content
    @Environment(\.i18n) var i18n
    var body: some View {
        if inAnotherCall {
            AxoTooltip.Root(label: i18n("icu:calling__in-another-call-tooltip")) { content }
        } else {
            content
        }
    }
}

/// `HeaderDropdownMenuContent`
struct ConversationHeaderMenu: View {
    let conversation: ConversationHeaderModel
    let isSignalConversation: Bool
    let isMissingMandatoryProfileSharing: Bool
    let actions: ConversationHeaderActions
    @Environment(\.i18n) var i18n

    var archiveItem: AxoDropdownMenu.Item {
        conversation.isArchived
            ? AxoDropdownMenu.Item(i18n("icu:moveConversationToInbox"), symbol: "archive-up", action: actions.onUnarchive)
            : AxoDropdownMenu.Item(i18n("icu:archiveConversation"), symbol: "archive", action: actions.onArchive)
    }

    var disappearingValue: Binding<String?> {
        let timer = conversation.expireTimer ?? 0
        let value = ExpirationTimer.defaultDurations.contains(timer) ? String(timer) : "custom"
        let change = actions.onDisappearingMessagesChange
        let custom = actions.onSetupCustomDisappearingTimeout
        return Binding(get: { value }, set: { v in
            guard let v else { return }
            if v == "custom" { custom() } else if let seconds = Int(v) { change(seconds) }
        })
    }

    var body: some View {
        let isGroup = conversation.type == .group
        if isSignalConversation {
            archiveItem
            AxoDropdownMenu.Item(i18n("icu:deleteConversation"), symbol: "trash", action: actions.onDeleteMessages)
        } else if isGroup && conversation.groupVersion != 2 {
            AxoDropdownMenu.Item(i18n("icu:showMembers"), symbol: "group", action: actions.onShowMembers)
            AxoDropdownMenu.Item(i18n("icu:allMediaMenuItem"), symbol: "album", action: actions.onViewAllMedia)
            AxoDropdownMenu.Separator()
            archiveItem
            AxoDropdownMenu.Item(i18n("icu:deleteConversation"), symbol: "trash", action: actions.onDeleteMessages)
        } else if !conversation.acceptedMessageRequest {
            if conversation.isBlocked {
                AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--Unblock"), symbol: "message-thread", action: actions.onUnblock)
            } else {
                AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--Block"), symbol: "block", action: actions.onBlock)
                AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--Accept"), symbol: "message-thread", action: actions.onAccept)
            }
            AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--ReportSpam"), symbol: "error-octagon", action: actions.onReportSpam)
            AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--DeleteChat"), symbol: "trash", action: actions.onDelete)
        } else {
            let disableTimer = !conversation.canChangeTimer || !conversation.acceptedMessageRequest || conversation.left || isMissingMandatoryProfileSharing
            if !disableTimer {
                AxoDropdownMenu.Sub(AxoDropdownMenu.SubTrigger(i18n("icu:disappearingMessages"), symbol: "timer")) {
                    AxoDropdownMenu.RadioGroup(value: disappearingValue) {
                        ForEach(ExpirationTimer.defaultDurations, id: \.self) { s in
                            AxoDropdownMenu.RadioItem(ExpirationTimer.format(i18n, s, capitalizeOff: true), value: String(s))
                        }
                        AxoDropdownMenu.RadioItem(i18n("icu:customDisappearingTimeOption"), value: "custom")
                    }
                }
            }
            if conversation.isMuted {
                AxoDropdownMenu.Item(i18n("icu:unmute"), symbol: "bell") { actions.onMuteExpirationChange(nil) }
            } else {
                AxoDropdownMenu.Sub(AxoDropdownMenu.SubTrigger(i18n("icu:muteNotificationsTitle"), symbol: "bell-slash")) {
                    ForEach(MuteOption.values(i18n), id: \.1) { name, option in
                        AxoDropdownMenu.Item(name) { actions.onMuteExpirationChange(option) }
                    }
                }
            }
            if !isGroup || conversation.groupVersion == 2 {
                AxoDropdownMenu.Item(i18n(isGroup ? "icu:showConversationDetails" : "icu:showConversationDetails--direct"), symbol: "settings",
                                     action: actions.onViewConversationDetails)
            }
            AxoDropdownMenu.Item(i18n("icu:allMediaMenuItem"), symbol: "album", action: actions.onViewAllMedia)
            AxoDropdownMenu.Separator()
            AxoDropdownMenu.Item(i18n("icu:ConversationHeader__menu__selectMessages"), symbol: "check-circle", action: actions.onSelectModeEnter)
            AxoDropdownMenu.Separator()
            if !conversation.markedUnread {
                AxoDropdownMenu.Item(i18n("icu:markUnread"), symbol: "message-badge", action: actions.onMarkUnread)
            }
            if conversation.isPinned {
                AxoDropdownMenu.Item(i18n("icu:unpinConversation"), symbol: "pin-slash", action: actions.onUnpin)
            } else {
                AxoDropdownMenu.Item(i18n("icu:pinConversation"), symbol: "pin", action: actions.onPin)
            }
            archiveItem
            if !conversation.terminated {
                if conversation.isBlocked {
                    AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--Unblock"), symbol: "message-thread", action: actions.onUnblock)
                } else {
                    AxoDropdownMenu.Item(i18n("icu:ConversationHeader__MenuItem--Block"), symbol: "block", action: actions.onBlock)
                }
            }
            AxoDropdownMenu.Item(i18n("icu:deleteConversation"), symbol: "trash", action: actions.onDeleteMessages)
            if isGroup && !conversation.terminated {
                AxoDropdownMenu.Item(i18n("icu:ConversationHeader__ContextMenu__LeaveGroupAction__title"), symbol: "leave", action: actions.onLeaveGroup)
            }
        }
    }
}

/// TimelineWarning (ts/components/conversation/TimelineWarning.dom.tsx + TimelineWarning.scss):
/// a min-56px bar with a 1px top border — the info icon (or `customInfo`), body-2 text with
/// a bold link, and the close (x) button.
public struct TimelineWarning<CustomInfo: View>: View {
    let onClose: () -> Void
    let onLink: () -> Void
    let text: [CSSTextRun]
    let customInfo: CustomInfo
    @Environment(\.i18n) var i18n

    public init(onClose: @escaping () -> Void, onLink: @escaping () -> Void, text: [CSSTextRun], @ViewBuilder customInfo: () -> CustomInfo) {
        self.onClose = onClose
        self.onLink = onLink
        self.text = text
        self.customInfo = customInfo()
    }

    public var body: some View {
        let iconColor = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray20)
        HStack(spacing: 0) {
            if CustomInfo.self == EmptyView.self {
                SignalIcon("v3/info/info", size: 20, color: iconColor)
            } else {
                customInfo.fixedSize()
            }
            CSSText(runs: text, style: LegacyType.body2(), onTap: { _ in onLink() })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            SwiftUI.Button(action: onClose) { SignalIcon("v3/x/x", size: 20, color: iconColor) }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:close"))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .cssTextColor(AxoColor(light: LegacyColor.gray65, dark: LegacyColor.gray15))
        .background(AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray80))
        .overlay(alignment: .top) { Rectangle().fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray65)).frame(height: 1) }
    }
}

/// CollidingAvatars (ts/components/CollidingAvatars.dom.tsx): two 24px avatars in a 36px box,
/// the second offset 12px; the first has the second's circle (+ a 1px gap) cut away.
public struct CollidingAvatars: View {
    let conversations: [ConversationAvatarData]
    public init(conversations: [ConversationAvatarData]) { self.conversations = conversations }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let first = conversations.first {
                ListAvatar(data: first, size: 24).clipShape(CollidingClip())
            }
            if conversations.count > 1 {
                ListAvatar(data: conversations[1], size: 24).offset(x: 12, y: 12)
            }
        }
        .frame(width: 36, height: 36, alignment: .topLeading)
    }
}

/// The clip path `M0 0 h1 v0.4166 A0.54166 0.54166 0 0 0.4166 1 H0 Z` in the avatar's box.
struct CollidingClip: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 0.4166 * r.height))
        // The arc of radius 0.54166 (centred on the second avatar, 0.5 + 0.5 = 1, 1) to (0.4166, 1).
        p.addArc(center: CGPoint(x: r.minX + r.width, y: r.minY + r.height), radius: 0.54166 * r.width,
                 startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// `LeaveGroupConfirmationDialog`: confirm leaving (disabled when we're the last admin).
public struct LeaveGroupConfirmationDialog: View {
    let cannotLeaveBecauseYouAreLastAdmin: Bool
    let onLeaveGroup: () -> Void
    @Environment(\.i18n) var i18n
    public init(cannotLeaveBecauseYouAreLastAdmin: Bool, onLeaveGroup: @escaping () -> Void) {
        self.cannotLeaveBecauseYouAreLastAdmin = cannotLeaveBecauseYouAreLastAdmin
        self.onLeaveGroup = onLeaveGroup
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: i18n("icu:ConversationHeader__LeaveGroupConfirmation__title"),
                              description: i18n("icu:ConversationHeader__LeaveGroupConfirmation__description")) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel"))
            AxoConfirmDialog.Action(i18n("icu:ConversationHeader__LeaveGroupConfirmation__confirmButton"), variant: .strongDestructive,
                                    disabled: cannotLeaveBecauseYouAreLastAdmin, action: onLeaveGroup)
        }
    }
}

/// `CannotLeaveGroupBecauseYouAreLastAdminAlert`
public struct CannotLeaveGroupBecauseYouAreLastAdminAlert: View {
    @Environment(\.i18n) var i18n
    public init() {}
    public var body: some View {
        AxoConfirmDialog.Root(title: nil, description: i18n("icu:ConversationHeader__CannotLeaveGroupBecauseYouAreLastAdminAlert__description")) {
            AxoConfirmDialog.Ok(i18n("icu:ok"))
        }
    }
}
