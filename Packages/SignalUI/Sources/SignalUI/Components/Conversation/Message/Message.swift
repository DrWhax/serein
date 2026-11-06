// Message (ts/components/conversation/Message.dom.tsx + `.module-message*` in _modules.scss):
// one timeline message — the row (`.module-message`, 16px inset; outgoing reversed), the
// group sender's 28px avatar (a spacer when collapsed below), and the bubble container
// (radius 18, padding 8px 12px, 6px above / below, 1px when collapsed; incoming surface,
// outgoing the chat colour) with the author, the text and the metadata.
//
// This is the core of the port: text messages, deleted messages, delivery states,
// disappearing timers and grouping. Quotes, attachments, link previews, stickers,
// reactions, polls, gift badges and contacts are added on top of it.

import SignalI18n
import SwiftUI

/// `BubbleColorRenderData`: a preset name, or a custom solid / gradient.
public enum BubbleColor: Sendable, Hashable {
    case preset(String)
    case solid(RGBA)
    case gradient(CSSLinearGradient)

    /// `getChatBubbleColorData`
    var data: (solid: RGBA?, gradient: CSSLinearGradient?) {
        switch self {
        case .preset(let name):
            if let s = AxoTokens.ChatBubble.solid(name) { return (s, nil) }
            return (nil, AxoTokens.ChatBubble.gradient(name))
        case .solid(let c): return (c, nil)
        case .gradient(let g): return (nil, g)
        }
    }

    public static let `default` = BubbleColor.preset("ultramarine")
}

/// The data a message renders (upstream PropsData, the parts ported so far).
public struct MessageProps {
    public struct Author: Sendable, Hashable {
        public var id: String
        public var title: String
        public var isMe = false
        public var color: String?
        public var avatar: RGBAImage?
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
        public static func == (a: Author, b: Author) -> Bool { a.id == b.id && a.title == b.title && a.isMe == b.isMe && a.color == b.color }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    public var id: String
    public var direction: MessageDirection
    public var conversationType: MessageRequestModel.Kind = .direct
    public var author: Author
    public var text: String?
    public var bodyRanges: [BodyRange] = []
    public var timestamp: Date
    public var status: MessageStatus?
    public var expirationLength: TimeInterval = 0
    public var expirationTimestamp: Date?
    public var isPinned = false
    public var isEdited = false
    public var isSMS = false
    public var shouldCollapseAbove = false
    public var shouldCollapseBelow = false
    public var shouldHideMetadata = false
    public var bubbleColor: BubbleColor = .default
    public var deletedForEveryone = false
    public var canRetryDeleteForEveryone = false
    public var deletedByAdmin: (title: String, isMe: Bool, contactNameColor: String?)?
    public var contactNameColor: String?
    public var contactLabel: ContactLabel?
    public var textPending = false
    public var displayLimit: Int?
    public var isSignalConversation = false
    /// `quote` (its direction and bubble colour come from the message, as `#renderQuote` passes them).
    public var quote: QuoteModel?
    public var scrollToQuotedMessage: (() -> Void)?
    /// `canBeDownloaded(textAttachment) && !isDownloaded(textAttachment)` for the long-message body.
    public var attachments: [MessageAttachment] = []
    public var isSticker = false
    /// Select mode (`isSelectMode` / `isSelected` / `toggleSelectMessage(shift, selected)`).
    public var isSelectMode = false
    public var isSelected = false
    public var toggleSelectMessage: ((Bool, Bool) -> Void)?
    /// `storyReplyContext`: the story this message replies (or reacts) to.
    public var storyReplyContext: StoryReplyContext?
    public var viewStory: (() -> Void)?
    public var poll: MessagePoll?
    public var canSendPollVote = false
    public var sendPollVote: (([Int]) -> Void)?
    public var showPollVotes: (() -> Void)?
    /// `isVoiceMessagePlayed`
    public var isVoiceMessagePlayed = false
    public var playAudio: (() -> Void)?
    /// The playing audio, when it is this message's (upstream's `active`).
    public var activeAudio: AudioActive?
    public var audioControls: AudioControls?
    public var reactions: [MessageReaction] = []
    public var toggleReactionViewer: (() -> Void)?
    /// `showEditHistoryModal`: makes the metadata's "Edited" a button.
    public var showEditHistory: (() -> Void)?
    public var conversationTitle: String?
    /// `contact`: a shared contact card.
    public var contact: SharedContact?
    public var openContactDetails: (() -> Void)?
    public var startConversationWithSharedContact: (() -> Void)?
    /// `previews` (only the first renders; attachments take precedence).
    public var previews: [LinkPreview] = []
    public var openLink: ((String) -> Void)?
    /// `activeCallConversationId`: the call you're in (a call-link preview's Join dims otherwise).
    public var activeCallConversationId: String?
    /// `attachmentDroppedDueToSize`: an attachment was too big to send.
    public var attachmentDroppedDueToSize = false
    /// `isTapToView` (view-once media) and its state.
    public var tapToView: TapToViewState?
    public var showLightbox: ((Int) -> Void)?
    /// `theme`: picks the default blurhash (nil: the environment's colour scheme).
    public var theme: ColorScheme?
    /// `_forceTapToPlay`: GIFs stop after their first play (as with reduced motion).
    public var forceTapToPlay = false
    public var showMediaNoLongerAvailableToast: (() -> Void)?
    public var kickOffAttachmentDownload: (() -> Void)?
    public var cancelAttachmentDownload: (() -> Void)?
    public var showTapToViewNotAvailableModal: (() -> Void)?
    public var textCanDownload = false
    /// `textAttachment.isPermanentlyUndownloadable`: the long body can't be fetched any more.
    public var textAttachmentUndownloadable = false
    public var kickOffBodyDownload: (() -> Void)?
    /// TimelineMessage: the hover buttons, the bubble's context menu and double-click reply
    /// (nil outside the timeline).
    public var actions: TimelineMessageActions?
    /// The looping player of a GIF (an MP4 with the GIF flag), once its file is here.
    public var gifPlayer: VideoPlaybackEngine?

    public init(id: String, direction: MessageDirection, author: Author, text: String?, timestamp: Date) {
        self.id = id
        self.direction = direction
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}

/// `.module-message__wrapper--select-mode`: the round checkbox 16px from the start, vertically
/// centred; selected rows get an 8% ultramarine wash; clicking toggles the selection.
struct SelectModeWrapper: ViewModifier {
    let isSelectMode: Bool
    let isSelected: Bool
    let authorTitle: String
    let toggle: ((Bool, Bool) -> Void)?
    @Environment(\.i18n) var i18n

    func body(content: Content) -> some View {
        if isSelectMode {
            content
                .overlay(alignment: .leading) { MessageSelectCheckbox(isSelected: isSelected).padding(.leading, 16) }
                .background(isSelected ? AxoColor(RGBA(LegacyColor.ultramarine.r, LegacyColor.ultramarine.g, LegacyColor.ultramarine.b, 0.08))
                                       : AxoColor(RGBA(0, 0, 0, 0)))
                .contentShape(Rectangle())
                .onTapGesture { toggle?(NSEvent.modifierFlags.contains(.shift), !isSelected) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(isSelected ? "1" : "0")
                .accessibilityHint(i18n("icu:Message__role-description"))
        } else {
            content
        }
    }
}

/// The message row with actions: `.module-message:hover` shows the buttons (the whole row
/// is the hover area), and double-clicking it replies.
struct MessageRowActions: ViewModifier {
    let actions: TimelineMessageActions?
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        if let actions {
            content
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .simultaneousGesture(TapGesture(count: 2).onEnded { actions.reply?() })
        } else {
            content
        }
    }
}

/// `storyReplyContext`
public struct StoryReplyContext: Sendable, Hashable {
    public var authorTitle: String
    public var isFromMe = false
    public var text: String?
    public var rawAttachment: QuotedAttachment?
    /// A reaction to the story rather than a reply.
    public var emoji: String?
    /// nil: the story is gone (`referencedMessageNotFound`).
    public var storyId: String?
    public init(authorTitle: String, text: String? = nil) {
        self.authorTitle = authorTitle
        self.text = text
    }
}

public struct Message: View {
    let props: MessageProps
    @Environment(\.i18n) var i18n
    @Environment(\.messageContainerMaxWidth) var maxWidth
    @Environment(\.conversationListNow) var fixedNow
    /// `.module-message` padding-inline (0 in EditHistoryMessagesModal).
    @Environment(\.messagePaddingInline) var paddingInline
    @Environment(\.messageShrinkWrapped) var shrinkWrapped
    @Environment(\.timeZone) var timeZone
    @Environment(\.colorScheme) var colorScheme
    @State private var hovering = false
    @State private var menu = MessageMenuState()
    @Environment(\.messageMenuAlwaysVisible) var menuAlwaysVisible

    public init(props: MessageProps) { self.props = props }

    static let sentStatuses: Set<MessageStatus> = [.delivered, .read, .sent, .viewed]
    static var textStyle: CSSTextStyle { LegacyType.body1().breakingWords() }   // overflow-wrap: break-word

    enum MetadataPlacement { case notRendered, inlineWithText, bottom, renderedElsewhere }

    /// `#isGenericAttachment`
    var isGenericAttachment: Bool {
        guard let first = props.attachments.first else { return false }
        return !first.isImage && !first.isVideo && !first.isAudio
    }

    /// `#getMetadataPlacement`
    var metadataPlacement: MetadataPlacement {
        let p = props
        if p.expirationLength == 0 && p.expirationTimestamp == nil && !p.isPinned && (p.status.map { Self.sentStatuses.contains($0) } ?? true)
            && p.shouldHideMetadata {
            return .notRendered
        }
        if let tv = p.tapToView {
            if !tv.isViewed && p.direction == .incoming && (tv.isExpired || tv.isError) { return .bottom }
            return .renderedElsewhere
        }
        if (p.text ?? "").isEmpty && !p.deletedForEveryone && !p.attachmentDroppedDueToSize {
            if isGenericAttachment { return .renderedElsewhere }
            if let a = p.attachments.first, a.isAudio, !a.isPermanentlyUndownloadable { return .renderedElsewhere }
            return .bottom
        }
        if (p.text ?? "").isEmpty && p.attachmentDroppedDueToSize { return .inlineWithText }
        if canRenderStickerLikeEmoji { return .bottom }
        if shouldShowActionButton { return .bottom }
        return .inlineWithText
    }

    /// `#canRenderStickerLikeEmoji`: a 1-emoji jumbomoji (without a quote) drops the bubble.
    var canRenderStickerLikeEmoji: Bool {
        guard let text = props.text, !props.deletedForEveryone, props.bodyRanges.isEmpty, props.quote == nil, props.attachments.isEmpty,
              props.previews.isEmpty, props.storyReplyContext == nil else { return false }
        return MessageBody.jumboEmojiCount(text) != nil
    }

    var shouldRenderAuthor: Bool {
        props.conversationType == .group && props.direction == .incoming && !props.shouldCollapseAbove
    }

    var metadata: MessageMetadata {
        MessageMetadata(direction: props.direction, timestamp: props.timestamp, status: props.status,
                        expiration: props.expirationLength > 0 ? (props.expirationLength, props.expirationTimestamp) : nil,
                        isPinned: props.isPinned, isEdited: props.isEdited, isSMS: props.isSMS, deletedForEveryone: props.deletedForEveryone,
                        canRetryDeleteForEveryone: props.canRetryDeleteForEveryone,
                        isOutlineOnlyBubble: props.deletedForEveryone || (props.attachmentDroppedDueToSize && (props.text ?? "").isEmpty),
                        isSticker: isStickerLike,
                        withImageNoCaption: isShowingImage, textPending: props.textPending, actions: {
                            var a = MessageMetadata.Actions()
                            a.showEditHistory = props.showEditHistory
                            return a
                        }())
    }

    /// `STICKER_SIZE`
    static let stickerSize: CGFloat = 200

    /// `isImage(attachments) || isVideo(attachments)` (the first attachment decides).
    var isVisualGrid: Bool {
        guard let first = props.attachments.first, !props.deletedForEveryone, props.tapToView == nil, !props.isSticker else { return false }
        return first.isImage || first.isVideo
    }

    /// The image grid with no caption: the metadata sits on the image.
    var isShowingImage: Bool { isVisualGrid && (props.text ?? "").isEmpty }

    /// `#shouldShowActionButton`: a lone call-link or sticker-pack preview.
    var shouldShowActionButton: Bool {
        guard props.previews.count == 1, let p = props.previews.first else { return false }
        return p.isCallLink || p.isStickerPack
    }

    /// The sticker-pack action's wrapper is a block, so its 6px margin-bottom collapses with the
    /// metadata's 3px; the call-link button sits in InAnotherCallTooltip's wrapper (no collapse).
    var actionMarginCollapses: Bool { shouldShowActionButton && props.previews.first?.isStickerPack == true }

    /// `#renderAction` (sticker packs: "View Pack").
    @ViewBuilder var action: some View {
        if shouldShowActionButton, let p = props.previews.first, p.isCallLink {
            // .module-message__action: "Join call"; half-transparent while you're in another call.
            let inAnotherCall = props.activeCallConversationId.map { p.callLinkRoomId == nil || $0 != p.callLinkRoomId } ?? false
            let incoming = props.direction == .incoming
            let text: AxoColor = incoming ? AxoColor(light: RGBA(hex: 0x315ff4), dark: LegacyColor.white) : AxoColor(LegacyColor.white)
            SwiftUI.Button { props.openLink?(p.url) } label: {
                CSSText(i18n("icu:calling__join"), style: LegacyType.body1(weight: 600), wrap: .nowrap, color: text)
                    .opacity(inAnotherCall ? 0.5 : 1)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(incoming ? AxoColor(light: LegacyColor.whiteAlpha70, dark: RGBA(1, 1, 1, 0.07)) : AxoColor(RGBA(1, 1, 1, 0.22)),
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 14).padding(.bottom, 4)
        } else if shouldShowActionButton, let p = props.previews.first, p.isStickerPack {
            AxoButton.Root(i18n("icu:stickers--ViewPack"), variant: props.direction == .outgoing ? .messageOutgoingPrimary : .messageIncomingPrimary,
                           size: .lg, width: .full) { props.openLink?(p.url) }
                .padding(.top, 8).padding(.bottom, 6)
        }
    }

    /// The link preview that renders (none with attachments).
    var linkPreview: LinkPreview? { props.attachments.isEmpty && !props.deletedForEveryone ? props.previews.first : nil }

    /// `#getWidth` / `getGridDimensions`: an image grid (or a full-size preview image) sets the
    /// bubble's width.
    var gridWidth: CGFloat? {
        if props.contact != nil && props.tapToView == nil { return 280 }
        if props.isSticker && !props.attachments.isEmpty { return Self.stickerSize + 8 * 2 }
        if !isVisualGrid, let p = linkPreview, p.isCallLink, !p.isFullSizeImage || p.image == nil { return 300 }
        if !isVisualGrid, let p = linkPreview, p.isFullSizeImage, let image = p.image {
            return imageDimensionsForTimeline(width: image.width, height: image.height).width
        }
        guard isVisualGrid else { return nil }
        if props.attachments[0].isGIF { return 300 + 2 }      // GIF_SIZE + the container's border
        if props.attachments.count == 1 {
            return imageDimensionsForTimeline(width: props.attachments[0].width, height: props.attachments[0].height).width
        }
        return 300
    }

    /// The bubble's content width (its width minus the 12px padding on each side).
    var contentWidth: CGFloat {
        let base = (gridWidth ?? maxWidth) - 24
        guard shrinkWrapped, gridWidth == nil, let text = props.text, !text.isEmpty else { return base }
        // Shrink-wrapped (StoryViewsNRepliesModal's flex-end rows): the max-width's
        // `calc(100% − 38px)` resolves against the message's own max-content width, which
        // reserves only the avatar column (28 + 8px, or nothing) for those 38px. The bubble ends
        // up that much short of its text + metadata spacer, which wraps the metadata.
        let deficit: CGFloat = 38 - (props.conversationType == .group && props.direction == .incoming ? 36 : 0)
        let spacer = metadataPlacement == .inlineWithText ? metadata.width(i18n: i18n, now: fixedNow ?? .now, timeZone: timeZone).rounded(.up) : nil
        let natural = CSSTextLayout.make(runs: [Emojify.run(text)] + spacerRuns(spacer), Self.textStyle, wrap: .nowrap, maxWidth: nil, colors: nil).width
        return min(base, max(0, natural - deficit))
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Signal (release-note) messages are centred.
            if props.direction == .outgoing || props.isSignalConversation { Spacer(minLength: 0) }
            if props.direction == .incoming { errorColumn }
            if props.conversationType == .group && props.direction == .incoming { avatar }
            containerWithReactions
            if props.direction == .outgoing { errorColumn }
            if props.direction == .incoming || props.isSignalConversation { Spacer(minLength: 0) }
        }
        .padding(.horizontal, paddingInline)
        .modifier(MessageRowActions(actions: props.isSelectMode ? nil : props.actions, hovering: $hovering))
        // --select-mode: incoming messages move aside (translate 16 + 22px) for the checkbox.
        .offset(x: props.isSelectMode && props.direction == .incoming ? 38 : 0)
        .modifier(SelectModeWrapper(isSelectMode: props.isSelectMode, isSelected: props.isSelected,
                                    authorTitle: props.author.title, toggle: props.toggleSelectMessage))
    }

    /// `#renderError`: a 28px column with the 20px error circle 4px from the bottom, 8px from
    /// the bubble (accent red; paused: gray-60 / gray-45).
    @ViewBuilder var errorColumn: some View {
        if let status = props.status, [.paused, .error, .partialSent].contains(status) {
            SignalIcon("v3/error/error-circle", size: 20,
                       color: status == .paused ? AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray45) : AxoColor(LegacyColor.accentRed))
                .padding(.bottom, 4)
                .frame(width: 28, alignment: props.direction == .incoming ? .leading : .trailing)
        }
    }

    /// `.module-message__author-avatar-container`
    /// `.module-message__container-outer`: the container, then the reactions overlapping its
    /// bottom by 6px (`--with-reactions`), at the column's end (incoming) or start (outgoing).
    @ViewBuilder var containerWithReactions: some View {
        if props.reactions.isEmpty || props.deletedForEveryone {
            container
        } else {
            VStack(alignment: props.direction == .incoming ? .trailing : .leading, spacing: 0) {
                container
                MessageReactions(reactions: props.reactions, outgoing: props.direction == .outgoing, toggleReactionViewer: props.toggleReactionViewer)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The actions' menu entries (`shouldShowAdditional`: the body overflows).
    var menuEntries: [TimelineMessageActions.Entry] {
        props.actions?.entries(i18n, shouldShowAdditional: MessageBodyReadMore.doesOverflow(props.text ?? ""),
                               openReactionPicker: { menu.reactionPicker = true }) ?? []
    }

    /// `#renderContainer`'s `maybeWrapWithContextMenu` (right-click the bubble for the menu)
    /// and `renderMenu` beside it — on the bubble's own box, not the row's max-width frame.
    @ViewBuilder func withActions(_ bubble: some View) -> some View {
        if props.actions != nil && !props.isSelectMode {
            AxoContextMenu.Root(location: $menu.contextMenu) { bubble } items: { MessageContextMenuItems(entries: menuEntries) }
                .overlay(alignment: props.direction == .incoming ? .trailing : .leading) { menuButtons }
        } else {
            bubble
        }
    }

    /// `renderMenu`: beside the bubble, 8px off (`--incoming` padding-inline-start, `--outgoing`
    /// padding-inline-end), centred on it; shown while the row is hovered or a menu is open.
    @ViewBuilder var menuButtons: some View {
        if let actions = props.actions, !props.isSelectMode, !props.isSignalConversation {
            let incoming = props.direction == .incoming
            // A zero-width anchor on the bubble's outer edge; the buttons run outwards from it.
            Color.clear.frame(width: 0)
                .overlay(alignment: incoming ? .leading : .trailing) {
                    MessageMenuButtons(direction: props.direction, actions: actions, entries: menuEntries, state: $menu)
                        .fixedSize()
                        .padding(incoming ? .leading : .trailing, 8)
                        .opacity(hovering || menu.anyOpen || menuAlwaysVisible ? 1 : 0)
                }
        }
    }

    var avatar: some View {
        Group {
            if props.shouldCollapseBelow {
                Color.clear.frame(width: 28, height: 28)
            } else {
                Avatar(strings: AvatarStrings(i18n: i18n), title: props.author.title, size: 28, conversationType: .direct,
                       color: props.author.color ?? "A200", image: props.author.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
            }
        }
        .padding(.bottom, props.reactions.isEmpty ? 6 : 15)      // --with-reactions
        .padding(.trailing, 8)
    }

    /// `isStickerLike`: a lone jumbomoji, or a sticker that can show (no quote): no bubble.
    var isStickerLike: Bool { canRenderStickerLikeEmoji || isShowingSticker }

    /// A sticker message showing its sticker (an undownloadable one shows the not-available block).
    var isShowingSticker: Bool {
        props.isSticker && props.quote == nil && (props.attachments.first.map { !$0.isPermanentlyUndownloadable } ?? false)
    }

    /// `.module-message__container` in the row (at most `maxWidth`, at its side).
    var container: some View {
        withActions(bubbleBox)
            .frame(maxWidth: maxWidth, alignment: props.isSignalConversation ? .center : props.direction == .outgoing ? .trailing : .leading)
    }

    /// The bubble itself, its own size.
    var bubbleBox: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii)
        return ShrinkToFitBlock {
            VStack(alignment: .leading, spacing: 0) {
                if shouldRenderAuthor { author }
                if props.deletedForEveryone {
                    regularContents
                } else if let tv = props.tapToView {
                    tapToView(tv)
                } else {
                    regularContents
                }
            }
            // `#getWidth`: a set width (image grid, sticker, contact) is the content box's.
            .frame(width: gridWidth.map { $0 - 24 }, alignment: .leading)
        }
        .padding(.horizontal, 12)
        // --emoji: padding-top 4px.
        .padding(.top, canRenderStickerLikeEmoji ? 4 : 8)
        .padding(.bottom, 8)
        .padding(props.deletedForEveryone && !isStickerLike ? 1 : 0)      // the 1px border
        .background { if !isStickerLike { background(shape) } }
        .overlay { if props.deletedForEveryone && !isStickerLike { DeletedBorder(shape: shape) } }
        .clipShape(shape)
        .padding(.top, props.shouldCollapseAbove ? 1 : 6)
        // --with-reactions: margin-bottom −6px (the reactions overlap the bubble).
        .padding(.bottom, bubbleBottomMargin)
        .overlay(alignment: .bottomTrailing) {
            // .module-message__metadata--with-image-no-caption: 9px above the bubble's bottom.
            if isShowingImage && metadataPlacement == .bottom { metadata.padding(.trailing, 12).padding(.bottom, 9 + bubbleBottomMargin) }
        }
        .frame(width: gridWidth)
    }

    /// `#renderContents` (the default case): quote, attachment, text and metadata.
    @ViewBuilder var regularContents: some View {
        if let q = quoteModel {
            // .module-message .module-quote: margin-inline −4px, margin-bottom 8px (its
            // 3px margin-top after the author collapses with the author's 3px).
            Quote(q, onClick: props.scrollToQuotedMessage ?? {}, strut: 0)
                .padding(.horizontal, -4)
                .padding(.bottom, 8)
        }
        if let first = props.attachments.first, first.isPermanentlyUndownloadable, !props.attachmentDroppedDueToSize,
           first.isAudio || props.isSticker {
            // `#renderSimpleAttachmentNotAvailable` (voice message, sticker)
            let hasText = !(props.text ?? "").isEmpty
            MessageAttachmentNotAvailable(info: i18n(first.isAudio ? "icu:attachmentNotAvailable__voice" : "icu:attachmentNotAvailable__sticker"),
                                          icon: first.isAudio ? "v3/waveform/waveform-slash" : "v3/sticker/sticker-slash", learnMore: nil,
                                          withContentAbove: quoteModel != nil || shouldRenderAuthor, withContentBelow: hasText,
                                          rule: props.direction == .outgoing ? AxoColor(LegacyColor.whiteAlpha30)
                                              : AxoColor(light: LegacyColor.blackAlpha10, dark: LegacyColor.whiteAlpha10))
                .cssTextColor(textColor)
        }
        if isShowingSticker {
            // .module-message__sticker-container: across the padding, 1px above the bubble's
            // top (4px below an author), 5px above metadata (−5 without).
            let metadataBelow = metadataPlacement != .notRendered
            let below = !(props.text ?? "").isEmpty || props.attachmentDroppedDueToSize || metadataBelow
            ImageGrid(attachments: props.attachments, direction: props.direction, isSticker: true, stickerSize: Self.stickerSize,
                      shouldCollapseAbove: props.shouldCollapseAbove, shouldCollapseBelow: props.shouldCollapseBelow,
                      withContentAbove: true, withContentBelow: true, blurHashDark: props.theme.map { $0 == .dark },
                      showVisualAttachment: props.showLightbox, showMediaNoLongerAvailableToast: props.showMediaNoLongerAvailableToast,
                      cancelDownload: props.cancelAttachmentDownload, startDownload: props.kickOffAttachmentDownload)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, -12)
                .padding(.top, shouldRenderAuthor ? 4 : -9)
                .padding(.bottom, below ? 5 : -5)
        }
        if isVisualGrid {
            // .module-message__attachment-container: across the bubble's padding (7px above
            // any text, 4px below the author or quote), white / gray-95 behind the images.
            let hasText = !(props.text ?? "").isEmpty || props.attachmentDroppedDueToSize
            let above = quoteModel != nil || shouldRenderAuthor
            Group {
                if props.attachments[0].isGIF {
                    MessageGIF(attachment: props.attachments[0], forceTapToPlay: props.forceTapToPlay, blurHashDark: props.theme.map { $0 == .dark },
                               showVisualAttachment: props.showLightbox.map { f in { f(0) } }, startDownload: props.kickOffAttachmentDownload,
                               cancelDownload: props.cancelAttachmentDownload, showMediaNoLongerAvailableToast: props.showMediaNoLongerAvailableToast,
                               player: props.gifPlayer)
                } else {
            ImageGrid(attachments: props.attachments, direction: props.direction, bottomOverlay: metadataPlacement != .notRendered,
                      shouldCollapseAbove: props.shouldCollapseAbove, shouldCollapseBelow: props.shouldCollapseBelow,
                      withContentAbove: above, withContentBelow: hasText, blurHashDark: props.theme.map { $0 == .dark },
                      showVisualAttachment: props.showLightbox,
                      showMediaNoLongerAvailableToast: props.showMediaNoLongerAvailableToast,
                      cancelDownload: props.cancelAttachmentDownload, startDownload: props.kickOffAttachmentDownload)
                }
            }
                .frame(maxWidth: .infinity)
                .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95))
                .clipped()
                .padding(.horizontal, -12)
                // margin-top 4px collapses with the author's 3px margin-bottom (4 in all) and
                // with a quote's 8px (8).
                .padding(.top, quoteModel != nil ? 0 : above ? 1 : -8)
                .padding(.bottom, hasText ? 7 : -8)
        }
        if let first = props.attachments.first, first.isAudio, !first.isPermanentlyUndownloadable, !props.deletedForEveryone, props.tapToView == nil {
            let hasText = !(props.text ?? "").isEmpty || props.attachmentDroppedDueToSize
            MessageAudio(attachment: first, waveform: first.audioWaveform, direction: props.direction, played: props.isVoiceMessagePlayed,
                         withContentAbove: quoteModel != nil || shouldRenderAuthor, withContentBelow: hasText,
                         metadata: metadataPlacement == .notRendered ? nil : metadata, onPlay: props.playAudio,
                         kickOffDownload: props.kickOffAttachmentDownload, cancelDownload: props.cancelAttachmentDownload,
                         active: props.activeAudio, controls: props.audioControls)
        }
        if let story = props.storyReplyContext {
            // `#renderStoryReplyContext`: "Reacted to …" over the story quote for reactions.
            if let _ = story.emoji {
                CSSText(props.direction == .incoming ? i18n("icu:Quote__story-reaction--you")
                            : i18n("icu:Quote__story-reaction", ["name": .string(story.authorTitle)]),
                        style: LegacyType.subtitle(),
                        color: props.direction == .incoming ? AxoColor(LegacyColor.gray60) : AxoColor(LegacyColor.whiteAlpha80))
                    .padding(.bottom, 6)
            }
            Quote({
                var q = QuoteModel(authorTitle: story.authorTitle, text: story.text)
                q.isFromMe = story.isFromMe
                q.direction = props.direction == .incoming ? .incoming : .outgoing
                q.isStoryReply = true
                q.rawAttachment = story.rawAttachment
                q.reactionEmoji = story.emoji
                q.referencedMessageNotFound = story.storyId == nil
                q.bubbleColor = props.bubbleColor
                return q
            }(), onClick: story.storyId != nil ? props.viewStory : nil, strut: 0)
                .padding(.horizontal, -4)
                .padding(.bottom, 8)
        }
        if isGenericAttachment, let first = props.attachments.first, !props.deletedForEveryone {
            let hasText = !(props.text ?? "").isEmpty
            let willShowMetadata = props.expirationLength > 0 || props.expirationTimestamp != nil || props.isPinned || !props.shouldHideMetadata
            MessageGenericAttachment(attachment: first, direction: props.direction, textColor: textColor, withContentAbove: quoteModel != nil || shouldRenderAuthor,
                                     withContentBelow: hasText, metadata: !hasText && willShowMetadata ? metadata : nil)
        }
        if let preview = linkPreview {
            // withContentAbove: a quote, or the author line (its 3px margin collapses into the
            // preview's 4px).
            let above = quoteModel != nil || (!props.shouldCollapseAbove && props.conversationType == .group && props.direction == .incoming)
            MessageLinkPreview(preview: preview, direction: props.direction, withContentAbove: above, shouldCollapseAbove: props.shouldCollapseAbove,
                               blurHashDark: props.theme.map { $0 == .dark }, open: props.openLink.map { f in { f(preview.url) } },
                               startDownload: props.kickOffAttachmentDownload, cancelDownload: props.cancelAttachmentDownload,
                               showMediaNoLongerAvailableToast: props.showMediaNoLongerAvailableToast)
                .padding(.horizontal, -12)
                .padding(.top, quoteModel != nil ? 0 : above ? 1 : -8)
                .padding(.bottom, 5)
        }
        if props.attachmentDroppedDueToSize { attachmentTooBig }
        if let poll = props.poll {
            PollMessageContents(poll: poll, direction: props.direction, canSendPollVote: props.canSendPollVote, sendPollVote: props.sendPollVote,
                                showVotes: props.showPollVotes, topMargin: shouldRenderAuthor ? 1 : 4)
        }
        if let contact = props.contact {
            // `#renderEmbeddedContact`: tapping an avatar that still needs downloading starts
            // (or cancels) the download instead of opening the details.
            let needsAction = contact.avatar.map { !$0.isDownloaded && !$0.isPermanentlyUndownloadable } ?? false
            EmbeddedContact(contact: contact, isIncoming: props.direction == .incoming, onClick: {
                if needsAction {
                    (contact.avatar?.pending == true ? props.cancelAttachmentDownload : props.kickOffAttachmentDownload)?()
                } else {
                    props.openContactDetails?()
                }
            }, onSendMessage: contact.canMessage ? (props.startConversationWithSharedContact ?? {}) : nil)
        }
        contents
    }

    /// `#renderUndownloadableTextAttachment`: "This message is incomplete" under a 0.5px rule,
    /// across the bubble.
    var undownloadableTextAttachment: some View {
        let rule = props.direction == .outgoing ? AxoColor(LegacyColor.whiteAlpha30) : AxoColor(light: LegacyColor.blackAlpha10, dark: LegacyColor.whiteAlpha10)
        return HStack(alignment: .top, spacing: 0) {
            SignalIcon("v3/error/error-circle", size: 20).padding(.trailing, 8)
            CSSText(i18n("icu:attachmentNotAvailable__longMessage"), style: Self.textStyle)
        }
        .cssTextColor(textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9 + 0.5)
        .padding(.horizontal, 12)
        .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 0.5) }
        .padding(.horizontal, -12)
        .padding(.top, 9)
    }

    /// `#renderAttachmentTooBig`: "Some attachments are too large to display." in an outlined
    /// block across the bubble, squared towards the content above / below it.
    var attachmentTooBig: some View {
        let hasText = !(props.text ?? "").isEmpty
        let above = quoteModel != nil || !props.attachments.isEmpty
        let incoming = props.direction == .incoming
        let collapseAbove = props.shouldCollapseAbove && !above, collapseBelow = props.shouldCollapseBelow && !hasText
        func corner(_ side: Bool, _ collapse: Bool, _ flat: Bool) -> CGFloat { flat ? 0 : (side && collapse ? 4 : 18) }
        let radii = RectangleCornerRadii(topLeading: corner(incoming, collapseAbove, above), bottomLeading: corner(incoming, collapseBelow, hasText),
                                         bottomTrailing: corner(!incoming, collapseBelow, hasText), topTrailing: corner(!incoming, collapseAbove, above))
        let shape = UnevenRoundedRectangle(cornerRadii: radii)
        let label = i18n(props.attachments.isEmpty ? "icu:message--attachmentTooBig--one" : "icu:message--attachmentTooBig--multiple")
        let bottomBorder = !hasText || colorScheme == .dark
        let spacer = !hasText && metadataPlacement == .inlineWithText
            ? metadata.width(i18n: i18n, now: fixedNow ?? .now, timeZone: timeZone).rounded(.up) : nil
        return CSSText(runs: [CSSTextRun(label, fontName: AxoFonts.interName(weight: 400, italic: true))] + spacerRuns(spacer), style: Self.textStyle,
                       color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
            .environment(\.cssTextWrapWidth, contentWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            // padding + the 1px border outside it. Above text, --content-below drops the bottom
            // border, but in dark the theme's `.dark-theme &` border outranks it.
            .padding(.top, 8 + 1)
            .padding(.bottom, bottomBorder ? 8 + 1 : 8)
            .padding(.horizontal, 12 + 1)
            .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95), in: shape)
            .overlay {
                shape.strokeBorder(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75), lineWidth: 1)
                    .padding(.bottom, bottomBorder ? 0 : -1)
            }
            .clipped()
            .padding(.horizontal, -12)
            .padding(.top, above ? 0 : -8)
            .padding(.bottom, hasText ? 7 : -8)
    }

    /// `#renderContents` for view-once media: the tap-to-view row (or the not-available block) and
    /// the bottom metadata.
    @ViewBuilder func tapToView(_ tv: TapToViewState) -> some View {
        let incoming = props.direction == .incoming
        let placement = metadataPlacement
        if incoming && !tv.isViewed && (tv.isError || tv.isExpired) {
            MessageAttachmentNotAvailable(info: i18n(tv.isExpired ? "icu:attachmentNotAvailable__tapToView" : "icu:attachmentNotAvailable__tapToViewCannotDownload"),
                                          icon: "v3/view_once/view_once-slash-bold", learnMore: props.showTapToViewNotAvailableModal ?? {},
                                          withContentAbove: quoteModel != nil || shouldRenderAuthor)
                .cssTextColor(textColor)
        } else {
            MessageTapToView(state: tv, attachment: props.attachments.first, direction: props.direction,
                             withContentAbove: placement != .notRendered && props.conversationType == .group && incoming,
                             metadata: placement == .notRendered ? nil : metadata)
        }
        if placement == .bottom { metadata.padding(.top, 3).frame(maxWidth: .infinity, alignment: .trailing) }
    }

    /// `#renderQuote`: the quote takes the message's direction and bubble colour; a collapsed-above
    /// bubble squares the quote's top corner on its side.
    var quoteModel: QuoteModel? {
        guard var q = props.quote, !props.deletedForEveryone else { return nil }
        q.direction = props.direction == .incoming ? .incoming : .outgoing
        q.bubbleColor = props.bubbleColor
        if props.shouldCollapseAbove { q.squaredTopCorner = props.direction == .incoming ? .leading : .trailing }
        return q
    }

    /// The bubble's bottom margin: 6px, 1px collapsed below, −6px over reactions.
    var bubbleBottomMargin: CGFloat {
        !props.reactions.isEmpty && !props.deletedForEveryone ? -6 : props.shouldCollapseBelow ? 1 : 6
    }

    /// Collapsed sides: 4px on the side facing the neighbouring message.
    var radii: RectangleCornerRadii {
        let small: CGFloat = 4, big: CGFloat = 18
        let incoming = props.direction == .incoming
        return RectangleCornerRadii(topLeading: incoming && props.shouldCollapseAbove ? small : big,
                                    bottomLeading: incoming && props.shouldCollapseBelow ? small : big,
                                    bottomTrailing: !incoming && props.shouldCollapseBelow ? small : big,
                                    topTrailing: !incoming && props.shouldCollapseAbove ? small : big)
    }

    @ViewBuilder func background(_ shape: UnevenRoundedRectangle) -> some View {
        if props.deletedForEveryone {
            Color.clear             // transparent, with DeletedBorder
        } else if props.isSignalConversation {
            // `bg-(--axo-color-legacy-signal-chat-message-bg)!` forces only the background
            // colour: an outgoing bubble's gradient chat colour (a background image) still
            // paints over it; a solid one (a background colour) loses to it.
            if props.direction == .outgoing, props.bubbleColor.data.gradient != nil, !(props.attachmentDroppedDueToSize && (props.text ?? "").isEmpty) {
                ZStack { shape.fill(AxoColor.legacySignalChatMessageBg); BubbleFill(color: props.bubbleColor, shape: shape) }
            } else {
                shape.fill(AxoColor.legacySignalChatMessageBg)
            }
        } else if props.direction == .incoming {
            shape.fill(AxoColor.surfaceMessageIncoming)
        } else if props.attachmentDroppedDueToSize && (props.text ?? "").isEmpty {
            // --module-message__container-bg is left unset: `background: var(…)` is transparent.
            Color.clear
        } else {
            BubbleFill(color: props.bubbleColor, shape: shape)
        }
    }

    /// `.module-message__author`: body-small-bold, 3px above the content.
    @ViewBuilder var author: some View {
        let name = ContactName(title: props.author.isMe ? i18n("icu:you") : props.author.title, contactNameColor: props.contactNameColor,
                               contactLabel: props.contactLabel, style: LegacyType.bodySmall(weight: 600), wrap: .truncate)
        if props.isSticker {
            // .module-message__author_with_sticker: 300px wide (past the narrow bubble), min 18px tall.
            name.frame(width: 300, alignment: .leading).frame(minHeight: 18, alignment: .top)
                .frame(width: contentWidth, alignment: .leading)
                .cssTextColor(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
        } else {
            name.padding(.bottom, 3)
        }
    }

    var textColor: AxoColor {
        // --delete-for-everyone: gray-60 in light; in dark the direction's colour still wins.
        if props.deletedForEveryone {
            return AxoColor(light: LegacyColor.gray60, dark: props.direction == .incoming ? LegacyColor.gray05 : LegacyColor.whiteAlpha90)
        }
        if props.isSignalConversation { return .labelPrimaryOncolor }
        return props.direction == .incoming ? AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05) : AxoColor(LegacyColor.whiteAlpha90)
    }

    @ViewBuilder var contents: some View {
        let placement = metadataPlacement
        let meta = metadata
        VStack(alignment: .trailing, spacing: 0) {
            // #updateMetadataWidth keeps Math.ceil of the measured width.
            let inline = placement == .inlineWithText
            text(spacer: inline && !props.textAttachmentUndownloadable
                    ? meta.width(i18n: i18n, now: fixedNow ?? .now, timeZone: timeZone).rounded(.up) : nil)
                // float: inline-end puts the metadata at the content box's end, even when a
                // wider sibling (quote, too-big block) widens the bubble past the text.
                .frame(maxWidth: inline ? .infinity : nil, alignment: .leading)
                .overlay(alignment: .bottomTrailing) { if inline && !props.textAttachmentUndownloadable { meta } }
            if props.textAttachmentUndownloadable {
                undownloadableTextAttachment
                    .overlay(alignment: .bottomTrailing) { if inline { meta } }
            }
            action
            // display: flex; justify-content: flex-end, across the content box. Its 3px margin-top
            // collapses through an empty text with the quote's 8px margin-bottom, and with the
            // action's 6px.
            if placement == .bottom && !isShowingImage {
                meta.padding(.top, ((quoteModel != nil || isShowingSticker) && (props.text ?? "").isEmpty) || actionMarginCollapses ? 0 : 3).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// `#renderText` / `#getMessageStatusContents`
    @ViewBuilder func text(spacer: CGFloat?) -> some View {
        let style = Self.textStyle
        Group {
            if props.deletedForEveryone {
                CSSText(runs: deletedRuns + spacerRuns(spacer), style: style)
            } else if props.direction == .incoming && props.status == .error {
                // .module-message__text--error: body-1-italic
                CSSText(runs: [CSSTextRun(i18n("icu:incomingError"), fontName: AxoFonts.interName(weight: 400, italic: true))] + spacerRuns(spacer),
                        style: style)
            } else if let text = props.text {
                MessageBodyReadMore(text: text, bodyRanges: props.bodyRanges, direction: props.direction, displayLimit: props.displayLimit,
                                    renderLocation: .timeline, textAttachment: MessageBodyTextAttachment(pending: props.textPending, canDownload: props.textCanDownload),
                                    style: style, linkColor: textColor, metadataSpacer: spacer,
                                    alignment: MessageBody.firstStrongDirection(text) == .rightToLeft ? .end : .start, messageExpanded: { _ in },
                                    kickOffBodyDownload: props.kickOffBodyDownload)
            }
        }
        .cssTextColor(textColor)
        // The bubble's content box: max-width minus the 12px padding on each side.
        .environment(\.cssTextWrapWidth, contentWidth)
    }

    func spacerRuns(_ w: CGFloat?) -> [CSSTextRun] {
        guard let w else { return [] }
        return [CSSTextRun("\u{200B}"), .inlineBlock("", CSSInlineBlock(paddingInline: (w + 10) / 2))]
    }

    /// The "deleted" line: the x-circle glyph, a no-break space and who deleted it.
    var deletedRuns: [CSSTextRun] {
        var glyph = CSSTextRun(String(AxoSymbol.inlineGlyph("x-circle")), fontName: "SignalSymbols-Thin")
        glyph.emojify = false
        let text: [CSSTextRun]
        if let admin = props.deletedByAdmin {
            if admin.isMe {
                text = [CSSTextRun(i18n("icu:message--deletedForEveryone--outgoing"))]
            } else {
                text = CSSTextRun.runs(i18n.richText("icu:message--deletedByAdmin", ["admin": .element("admin")]),
                                       elements: ["admin": CSSTextRun(admin.title, fontName: AxoFonts.interName(weight: 700),
                                                                      color: admin.contactNameColor.map { AxoTokens.Contact.color($0) })])
            }
        } else if props.direction == .outgoing {
            text = [CSSTextRun(i18n("icu:message--deletedForEveryone--outgoing"))]
        } else {
            text = CSSTextRun.runs(i18n.richText("icu:message--deletedForEveryone--incoming", ["name": .element("name")]),
                                   elements: ["name": CSSTextRun(props.author.title)])
        }
        return [glyph, CSSTextRun("\u{00A0}")] + text
    }
}

/// CSS shrink-to-fit: the content's natural width, or the whole available width once it
/// has to wrap.
struct ShrinkToFitBlock: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        guard let available = proposal.width, natural.width > available else { return natural }
        return CGSize(width: available, height: child.sizeThatFits(ProposedViewSize(width: available, height: nil)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The outgoing bubble's chat colour (solid, or a gradient). Gradients are
/// `background-attachment: fixed`: one gradient over the viewport, each bubble showing its
/// part of it (`\.chatColorViewport`, in global coordinates; without one, the bubble's own box).
struct BubbleFill: View {
    let color: BubbleColor
    let shape: UnevenRoundedRectangle
    @Environment(\.chatColorViewport) var viewport
    var body: some View {
        let data = color.data
        if let solid = data.solid {
            shape.fill(solid.color)
        } else if let g = data.gradient {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let box = viewport ?? frame
                CSSLinearGradientFill(g)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX - frame.minX, y: box.minY - frame.minY)
            }
            .clipShape(shape)
        }
    }
}

/// `--deleted-for-everyone`: a transparent bubble with a 1px gray-25 (dark: #3b3b3b) border.
struct DeletedBorder: View {
    let shape: UnevenRoundedRectangle
    var body: some View { shape.strokeBorder(AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray75), lineWidth: 1) }
}

extension EnvironmentValues {
    /// `.module-message__container-outer` max-width: min(306, 100% − 38); 50vw in a wide timeline, 370 in a medium one.
    @Entry public var messageContainerMaxWidth: CGFloat = 306
    /// The viewport (global coordinates) fixed-attachment chat colour gradients span.
    @Entry public var chatColorViewport: CGRect? = nil
}

extension EnvironmentValues {
    /// `.module-message { padding-inline }`: 16px in the timeline.
    @Entry public var messagePaddingInline: CGFloat = 16
    /// The message is sized to its content (a flex-end row), not to the timeline's width.
    @Entry public var messageShrinkWrapped = false
}
