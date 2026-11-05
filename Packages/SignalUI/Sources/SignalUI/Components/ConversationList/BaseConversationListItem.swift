// BaseConversationListItem (ts/components/conversationList/BaseConversationListItem.dom.tsx,
// `.module-conversation-list__item--contact-or-conversation` in stylesheets/_modules.scss):
// avatar, header (name + date), message line with status icon and unread indicators.

import SignalI18n
import SwiftUI

extension AvatarStrings {
    /// The Avatar strings from upstream's message catalog.
    public init(i18n: Localizer) {
        self.init(contactAvatarAlt: { i18n("icu:contactAvatarAlt", ["name": .string($0)]) }, unknownContact: i18n("icu:unknownContact"),
                  deletedAccount: i18n("icu:deletedAccount"), view: i18n("icu:view"))
    }
}

/// The avatar a list row shows (Avatar props).
public struct ConversationAvatarData {
    public var title: String
    public var conversationType: AvatarConversationType
    public var color: String?
    public var image: RGBAImage?
    public var hasAvatar: Bool
    public var placeholderGradient: (start: RGBA, end: RGBA)?
    public var noteToSelf: Bool
    public var searchResult: Bool

    public init(title: String, conversationType: AvatarConversationType = .direct, color: String? = nil, image: RGBAImage? = nil,
                hasAvatar: Bool = false, placeholderGradient: (start: RGBA, end: RGBA)? = nil, noteToSelf: Bool = false,
                searchResult: Bool = false) {
        self.title = title
        self.conversationType = conversationType
        self.color = color
        self.image = image
        self.hasAvatar = hasAvatar
        self.placeholderGradient = placeholderGradient
        self.noteToSelf = noteToSelf
        self.searchResult = searchResult
    }
}

struct ListAvatar: View {
    let data: ConversationAvatarData
    let size: CGFloat
    @Environment(\.i18n) var i18n

    var body: some View {
        Avatar(strings: AvatarStrings(i18n: i18n), title: data.title, size: size, conversationType: data.conversationType,
               color: data.color ?? "A200", image: data.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: data.hasAvatar,
               placeholderGradient: data.placeholderGradient ?? AxoTokens.Avatar.gradient(hash: 0), noteToSelf: data.noteToSelf,
               searchResult: data.searchResult)
    }
}

public struct BaseConversationListItem<HeaderName: View, MessageText: View, StatusIcon: View>: View {
    let avatar: ConversationAvatarData
    let avatarSize: CGFloat
    let headerName: HeaderName
    let headerDate: Date?
    let messageText: MessageText?
    let messageStatusIcon: StatusIcon?
    let messageTextIsAlwaysFullSize: Bool
    let isSelected: Bool
    let disabled: Bool
    let markedUnread: Bool
    let unreadCount: Int
    let unreadMentionsCount: Int
    let buttonAriaLabel: String?
    let onClick: (() -> Void)?
    let onMouseDown: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListWidthBreakpoint) var breakpoint
    @State private var hovered = false

    public init(avatar: ConversationAvatarData, avatarSize: CGFloat = 48, headerDate: Date?, messageTextIsAlwaysFullSize: Bool = false,
                isSelected: Bool = false, disabled: Bool = false, markedUnread: Bool = false, unreadCount: Int = 0, unreadMentionsCount: Int = 0,
                buttonAriaLabel: String? = nil, onClick: (() -> Void)?, onMouseDown: (() -> Void)? = nil,
                @ViewBuilder headerName: () -> HeaderName, messageText: MessageText?, messageStatusIcon: StatusIcon?) {
        self.avatar = avatar
        self.avatarSize = avatarSize
        self.headerName = headerName()
        self.headerDate = headerDate
        self.messageText = messageText
        self.messageStatusIcon = messageStatusIcon
        self.messageTextIsAlwaysFullSize = messageTextIsAlwaysFullSize
        self.isSelected = isSelected
        self.disabled = disabled
        self.markedUnread = markedUnread
        self.unreadCount = unreadCount
        self.unreadMentionsCount = unreadMentionsCount
        self.buttonAriaLabel = buttonAriaLabel
        self.onClick = onClick
        self.onMouseDown = onMouseDown
    }

    /// util/isConversationUnread.std.ts
    var isUnread: Bool { markedUnread || unreadCount > 0 }
    var narrow: Bool { breakpoint == .narrow }

    var background: AxoColor? {
        if isSelected { return .fillPrimaryPressed }
        if hovered && !disabled { return .fillPrimary }
        return nil
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let row = HStack(alignment: .center, spacing: 0) {
            ListAvatar(data: avatar, size: avatarSize)
                .overlay(alignment: .top) { if isUnread && narrow { narrowIndicators } }
            if !narrow || messageText != nil {
                content.padding(.leading, 12).opacity(disabled ? 0.5 : 1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .leading)
        .background { if let background { shape.fill(background) } }
        .contentShape(shape)
        .padding(.vertical, 2)
        .onHover { hovered = $0 }
        Group {
            if let onClick {
                SwiftUI.Button(action: onClick) { row }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .simultaneousGesture(TapGesture().onEnded { onMouseDown?() })
                    .accessibilityLabel(buttonAriaLabel ?? i18n("icu:BaseConversationListItem__aria-label", ["title": .string(avatar.title)]))
            } else {
                row
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !narrow {
                HStack(alignment: .center, spacing: 0) {
                    headerName
                        .cssTextColor(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let headerDate { ConversationListTimestamp(date: headerDate).padding(.leading, 6).fixedSize() }
                }
            }
            if messageText != nil || isUnread {
                HStack(alignment: .top, spacing: 0) {
                    if let messageText, !narrow {
                        messageText
                            .frame(maxWidth: .infinity, minHeight: messageTextIsAlwaysFullSize ? 36 : nil,
                                   maxHeight: messageTextIsAlwaysFullSize ? 36 : nil, alignment: .topLeading)
                            .clipped()
                    } else {
                        Spacer(minLength: 0)
                    }
                    if !narrow, let messageStatusIcon { messageStatusIcon }
                    if isUnread && !narrow {
                        ConversationListUnreadIndicators(unreadCount: unreadCount, unreadMentionsCount: unreadMentionsCount)
                            .padding(.leading, 10)
                            .padding(.top, 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// In a narrow list the indicators sit on the avatar's top corners, ringed in the row's
    /// background (box-shadow 0 0 0 3px).
    var narrowIndicators: some View {
        let ring = background ?? .surfaceSecondary
        return ZStack {
            if unreadMentionsCount > 0 {
                ConversationListUnreadIndicator(kind: .mentions).ring(ring)
                    .frame(maxWidth: .infinity, alignment: .leading).offset(x: -5)
            }
            ConversationListUnreadIndicator(kind: unreadCount > 0 ? .messages(unreadCount) : .markedUnread).ring(ring)
            .frame(maxWidth: .infinity, alignment: .trailing).offset(x: 5)
        }
        .offset(y: -1)
    }
}

/// The header date: `formatDateTimeShort`, refreshed every minute.
struct ConversationListTimestamp: View {
    let date: Date
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    var body: some View {
        if let fixedNow {
            label(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in label(context.date) }
        }
    }

    func label(_ now: Date) -> some View {
        CSSText(FormatTimestamp.dateTimeShort(date, now: now, i18n: i18n, timeZone: timeZone), style: LegacyType.caption(), wrap: .nowrap,
                color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
    }
}

extension EnvironmentValues {
    /// A fixed "now" for relative timestamps (conversation list and timeline; stories and tests);
    /// nil follows the clock.
    @Entry public var conversationListNow: Date? = nil
}

struct ConversationListUnreadIndicators: View {
    let unreadCount: Int
    let unreadMentionsCount: Int
    var body: some View {
        HStack(spacing: 4) {
            if unreadMentionsCount > 0 { ConversationListUnreadIndicator(kind: .mentions) }
            if unreadCount > 0 { ConversationListUnreadIndicator(kind: .messages(unreadCount)) } else {
                ConversationListUnreadIndicator(kind: .markedUnread)
            }
        }
        .fixedSize()
    }
}

/// `__unread-indicator`: an 18px accent pill with the count, the @ icon, or nothing.
struct ConversationListUnreadIndicator: View {
    enum Kind { case markedUnread, messages(Int), mentions }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .markedUnread:
                Color.clear.frame(width: 0, height: 0)
            case .messages(let n):
                // font-caption-bold at weight 500, line-height 100% (11px).
                CSSText(String(n), style: CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 11, lineHeight: 11, letterSpacing: 0.06),
                        wrap: .nowrap, color: .labelPrimaryOncolor)
                    .padding(.horizontal, 4)
            case .mentions:
                SignalIcon("v3/at/at", size: 12, color: .labelPrimaryOncolor)
            }
        }
        .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
        .background(RoundedRectangle(cornerRadius: 10).fill(AxoColor.fillAccent))
    }

    func ring(_ color: AxoColor) -> some View {
        self.background(RoundedRectangle(cornerRadius: 12).fill(color).padding(-3))
    }
}

/// `__status-icon--<status>`: 12px (18px wide for delivered / read), gray, red for errors.
public enum LastMessageStatus: String, Sendable { case paused, error, partialSent = "partial-sent", sending, sent, delivered, read, viewed }

struct MessageStatusIcon: View {
    let status: LastMessageStatus
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    var body: some View {
        let normal = AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25)
        let (icon, color, width): (String, AxoColor, CGFloat) = switch status {
        case .sending: ("v3/message_status/messagestatus-sending", AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45), 12)
        case .sent: ("v3/message_status/messagestatus-sent", normal, 12)
        case .delivered: ("v3/message_status/messagestatus-delivered", normal, 18)
        case .read, .viewed: ("v3/message_status/messagestatus-read", normal, 18)
        case .error, .partialSent: ("v3/error/error-circle", AxoColor(LegacyColor.accentRed), 12)
        case .paused: ("v3/error/error-circle", AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45), 12)
        }
        Group {
            if status == .sending && !animationsDisabled {
                TimelineView(.animation) { t in
                    SignalIcon(icon, color: color)
                        .rotationEffect(.degrees(360 * (t.date.timeIntervalSinceReferenceDate / 4).truncatingRemainder(dividingBy: 1)))
                }
            } else {
                // mask-size 100%: the SVG scaled to the box width, height by aspect ratio.
                SignalIcon(icon, color: color)
            }
        }
        .frame(width: width, height: 12)
        .padding(.top, 4)
        .padding(.leading, 6)
    }
}

/// TypingAnimation (ts/components/conversation/TypingAnimation.dom.tsx): three 6px dots in a
/// 38×8 box pulsing in turn (the left pane's `typing-animation-bare`, opacity only).
public struct TypingAnimation: View {
    public enum Color: Sendable { case light }
    let color: Color?
    /// 38px; 30px in a message bubble (`.module-message__typing-animation-container`).
    let width: CGFloat
    @Environment(\.i18n) var i18n
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    public init(color: Color? = nil, width: CGFloat = 38) {
        self.color = color
        self.width = width
    }

    public var body: some View {
        let fill = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.white)
        Group {
            if animationsDisabled {
                dots(fill, phase: nil)
            } else {
                TimelineView(.animation) { t in dots(fill, phase: t.date.timeIntervalSinceReferenceDate) }
            }
        }
        .help(i18n("icu:typingAlt"))
        .accessibilityLabel(i18n("icu:typingAlt"))
    }

    static func opacity(_ time: Double?, delay: Double) -> Double {
        guard let time else { return 0.4 }
        let p = ((time - delay).truncatingRemainder(dividingBy: 1.6) + 1.6).truncatingRemainder(dividingBy: 1.6) / 1.6
        if p < 0.2 { return 0.4 + 0.6 * (p / 0.2) }
        if p < 0.4 { return 1 - 0.6 * ((p - 0.2) / 0.2) }
        return 0.4
    }

    func dots(_ fill: AxoColor, phase: Double?) -> some View {
        HStack(spacing: 0) {
            Circle().fill(fill).frame(width: 6, height: 6).opacity(Self.opacity(phase, delay: 0))
            Spacer(minLength: 0)
            Circle().fill(fill).frame(width: 6, height: 6).opacity(Self.opacity(phase, delay: 0.16))
            Spacer(minLength: 0)
            Circle().fill(fill).frame(width: 6, height: 6).opacity(Self.opacity(phase, delay: 0.32))
        }
        .padding(.horizontal, 1)
        .frame(width: width, height: 8)
    }
}

/// OfficialChatInlineBadge: the accent seal-check glyph with a white check behind its centre.
public struct OfficialChatInlineBadge: View {
    let size: CGFloat
    let weight: Int
    public init(size: CGFloat, weight: Int = 400) {
        self.size = size
        self.weight = weight
    }
    public var body: some View {
        AxoSymbol.InlineGlyph("seal-check-fill", size: size, weight: weight)
            .cssTextColor(.fillAccent)
            .background { Circle().fill(AxoColor.labelPrimaryOncolor).scaleEffect(0.5) }
            .accessibilityHidden(true)
    }
}
