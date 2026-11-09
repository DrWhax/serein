// Port of ts/components/StoryViewer.dom.tsx (+ StoryViewer.scss, StoryProgressSegment.scss):
// the full-window story viewer — the story's picture tiled at its `contain` size behind a 90px
// blur and a 20% shade, the story itself contained in the window, the top / bottom
// protections, and the meta column (56.25vh wide, centred at the bottom): the caption (with
// "Read more"), sender / group / time / distribution list, pause, mute and more, a progress
// segment per story, and the reply / views / send-status action; the close button top right.

import SignalI18n
import SwiftUI

public struct StoryViewerData {
    public var story: StoryViewData
    public var caption: String?
    public var group: StoryConversation?
    public var distributionListName: String?
    public var isMe: Bool
    public var numStories: Int
    public var currentIndex: Int
    /// How far the current segment has played (0…1).
    public var progress: Double
    /// The story is a video with sound.
    public var hasAudio: Bool
    public var hasAllStoriesUnmuted: Bool
    public var canReply: Bool
    public var isGroupStory: Bool
    /// We sent it (`sendState` is set).
    public var isSent: Bool
    public var hasViewReceiptSetting: Bool
    public var viewCount: Int
    public var replyCount: Int
    public var isHidden: Bool
    public var isSignalConversation: Bool

    public init(story: StoryViewData, caption: String? = nil, group: StoryConversation? = nil, distributionListName: String? = nil, isMe: Bool = false,
                numStories: Int = 1, currentIndex: Int = 0, progress: Double = 0, hasAudio: Bool = false, hasAllStoriesUnmuted: Bool = true,
                canReply: Bool = false, isGroupStory: Bool = false, isSent: Bool = false, hasViewReceiptSetting: Bool = true, viewCount: Int = 0,
                replyCount: Int = 0, isHidden: Bool = false, isSignalConversation: Bool = false) {
        self.story = story
        self.caption = caption
        self.group = group
        self.distributionListName = distributionListName
        self.isMe = isMe
        self.numStories = numStories
        self.currentIndex = currentIndex
        self.progress = progress
        self.hasAudio = hasAudio
        self.hasAllStoriesUnmuted = hasAllStoriesUnmuted
        self.canReply = canReply
        self.isGroupStory = isGroupStory
        self.isSent = isSent
        self.hasViewReceiptSetting = hasViewReceiptSetting
        self.viewCount = viewCount
        self.replyCount = replyCount
        self.isHidden = isHidden
        self.isSignalConversation = isSignalConversation
    }
}

public struct StoryViewerActions {
    public var onClose: () -> Void = {}
    public var viewPrevious: () -> Void = {}
    public var viewNext: () -> Void = {}
    public var setPaused: (Bool) -> Void = { _ in }
    public var setHasAllStoriesUnmuted: (Bool) -> Void = { _ in }
    public var showNoSoundToast: () -> Void = {}
    public var showDetails: () -> Void = {}
    public var showReplies: () -> Void = {}
    public var deleteStory: () -> Void = {}
    public var hideStory: () -> Void = {}
    public var goToConversation: () -> Void = {}
    public var retrySend: () -> Void = {}
    public init() {}
}

public struct StoryViewer: View {
    let data: StoryViewerData
    let actions: StoryViewerActions
    @State var paused = false
    @State var hasExpandedCaption = false
    @State var wasManuallyRetried = false
    @State var moreOpen = false
    @State var hoveredArrow: Int?
    @Environment(\.i18n) var i18n
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight

    public init(data: StoryViewerData, actions: StoryViewerActions = StoryViewerActions()) {
        self.data = data
        self.actions = actions
    }

    static let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)

    /// `getStoryBackground`: the text story's background, else the picture tiled from the top
    /// left at its natural size (the inline `background:` shorthand resets the stylesheet's
    /// `background-size: contain` to auto), else black 90%. Drawn `pad` larger on every side so
    /// the 90px backdrop blur reads tiles (not transparency) past the window.
    func overlay(_ size: CGSize, pad: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let text = data.story.attachment?.textAttachment {
                StoryColors.background(text).frame(width: size.width, height: size.height).offset(x: pad, y: pad)
                    .background { StoryColors.background(text) }
            } else if let image = data.story.attachment?.image {
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let c0 = -Int((pad / w).rounded(.up)), c1 = Int(((size.width + pad) / w).rounded(.up))
                let r0 = -Int((pad / h).rounded(.up)), r1 = Int(((size.height + pad) / h).rounded(.up))
                ForEach(r0..<max(r0 + 1, r1), id: \.self) { r in
                    ForEach(c0..<max(c0 + 1, c1), id: \.self) { c in
                        PixelImage(image, fit: .fill).frame(width: w, height: h).offset(x: pad + CGFloat(c) * w, y: pad + CGFloat(r) * h)
                    }
                }
            } else {
                Color(rgba: LegacyColor.blackAlpha90)
            }
        }
        .frame(width: size.width + 2 * pad, height: size.height + 2 * pad, alignment: .topLeading)
    }

    func icon(_ name: String) -> some View {
        SignalIcon(name, size: 20, color: Self.white, mask: true).frame(width: 20, height: 20)
    }

    var muteButton: some View {
        let (name, label): (String, String) = data.hasAudio
            ? (data.hasAllStoriesUnmuted ? ("v3/speaker/speaker", i18n("icu:StoryViewer__mute")) : ("v3/speaker/speaker-slash", i18n("icu:StoryViewer__unmute")))
            : ("v3/speaker/speaker-x", i18n("icu:Stories__toast--hasNoSound"))
        return Button {
            if data.hasAudio { actions.setHasAllStoriesUnmuted(!data.hasAllStoriesUnmuted) } else { actions.showNoSoundToast() }
        } label: { icon(name) }
            .buttonStyle(UndimmedButtonStyle())
            .accessibilityLabel(label)
            .padding(.horizontal, 24)
    }

    @ViewBuilder var moreMenu: some View {
        if data.isSent || !data.isSignalConversation {
            AxoThemeOverride(theme: .forceDark) {
                AxoDropdownMenu.Root(isOpen: $moreOpen) {
                    AxoIconButton.Root(label: i18n("icu:MyStories__more"), variant: .impliedSecondary, size: .sm, symbol: "more")
                } items: {
                    AxoDropdownMenu.Item(i18n("icu:StoryListItem__info"), symbol: "info", action: actions.showDetails)
                    if data.isSent {
                        AxoDropdownMenu.Item(i18n("icu:StoryListItem__delete"), symbol: "trash", action: actions.deleteStory)
                    } else {
                        if data.isHidden {
                            AxoDropdownMenu.Item(i18n("icu:StoryListItem__unhide"), symbol: "check-circle", action: actions.hideStory)
                        } else {
                            AxoDropdownMenu.Item(i18n("icu:StoryListItem__hide"), symbol: "x-circle", action: actions.hideStory)
                        }
                        AxoDropdownMenu.Item(i18n("icu:StoryListItem__go-to-chat"), symbol: "open", action: actions.goToConversation)
                    }
                }
            }
        }
    }

    var playbackBar: some View {
        let sender = data.story.sender
        let title = data.isMe ? i18n("icu:you") : sender.title
        return HStack(alignment: .center, spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: sender.title, size: 28, conversationType: .direct, color: sender.color,
                   image: sender.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: sender.avatar != nil)
            if let group = data.group {
                Avatar(strings: AvatarStrings(i18n: i18n), title: group.title, size: 28, conversationType: .group, color: group.color,
                       image: group.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: group.avatar != nil)
                    .padding(.leading, -8)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CSSText(data.group.map { i18n("icu:Stories__from-to-group", ["name": .string(title), "group": .string($0.title)]) } ?? title,
                            style: LegacyType.body1(weight: 600), wrap: .nowrap, color: Self.white)
                    MessageTimestamp(timestamp: data.story.timestamp, isRelativeTime: true, style: LegacyType.body2(),
                                     color: AxoColor(light: LegacyColor.whiteAlpha60, dark: LegacyColor.whiteAlpha60))
                }
                if let list = data.distributionListName {
                    HStack(spacing: 6) {
                        SignalIcon("v3/stories/stories-fill-compact", size: 14, color: AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha80),
                                   mask: true).frame(width: 14, height: 14)
                        CSSText(list, style: LegacyType.body2(), wrap: .nowrap, color: AxoColor(light: LegacyColor.whiteAlpha80, dark: LegacyColor.whiteAlpha80))
                    }
                }
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
            Button { paused.toggle(); actions.setPaused(paused) } label: { icon(paused ? "v3/play/play-fill" : "v3/pause/pause") }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel(i18n(paused ? "icu:StoryViewer__play" : "icu:StoryViewer__pause"))
            muteButton
            moreMenu
        }
        .frame(minHeight: 28)
    }

    /// `StoryProgressSegment`s: 2px, white 40% with the white bar, 12px above, 1px apart each side.
    var progress: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(1, data.numStories), id: \.self) { i in
                GeometryReader { g in
                    let fill: Double = i < data.currentIndex ? 1 : i == data.currentIndex ? data.progress : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(rgba: LegacyColor.whiteAlpha40))
                        RoundedRectangle(cornerRadius: 2).fill(Color(rgba: LegacyColor.white)).frame(width: g.size.width).offset(x: -(1 - fill) * g.size.width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .frame(height: 2)
                .padding(.horizontal, 1)
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder var actionsRow: some View {
        let status = data.story.sendStatus
        HStack(spacing: 0) {
            if (status == .failed || status == .partiallySent) && data.isSent && !wasManuallyRetried {
                Button {
                    wasManuallyRetried = true
                    actions.retrySend()
                } label: {
                    HStack(spacing: 12) {
                        SignalIcon("v3/error/error-circle", size: 18, color: AxoColor(light: LegacyColor.accentRed, dark: LegacyColor.accentRed), mask: true)
                            .frame(width: 18, height: 18)
                        CSSText(i18n(status == .failed ? "icu:StoryViewer__failed" : "icu:StoryViewer__partial-fail"), style: LegacyType.body1(), wrap: .nowrap,
                                color: Self.white)
                    }
                }
                .buttonStyle(UndimmedButtonStyle())
            }
            if status == .sending && data.isSent {
                HStack(spacing: 0) {
                    Spinner(svgSize: .small).padding(.trailing, 12)
                    CSSText(i18n("icu:StoryViewer__sending"), style: LegacyType.body1(), wrap: .nowrap, color: Self.white)
                }
            }
            if data.canReply || (data.isSent && status == .sent) {
                Button(action: actions.showReplies) { replyLabel }.buttonStyle(UndimmedButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    @ViewBuilder var replyLabel: some View {
        let gray05 = AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray05)
        if data.isSent || data.replyCount > 0 {
            HStack(spacing: 4) {
                if data.isSent && !data.hasViewReceiptSetting && data.replyCount == 0 {
                    CSSText(i18n("icu:StoryViewer__views-off"), style: LegacyType.body1(), wrap: .nowrap, color: gray05)
                } else {
                    let views = data.isSent && data.hasViewReceiptSetting
                        ? i18n.richText("icu:MyStories__views--strong", ["views": .number(Double(data.viewCount))]) : nil
                    let replies = data.replyCount > 0 ? i18n.richText("icu:MyStories__replies", ["replyCount": .number(Double(data.replyCount))]) : nil
                    let runs = (views.map { CSSTextRun.runs($0, tags: ["strong": .bold]) } ?? [])
                        + (views != nil && replies != nil ? [CSSTextRun(" ")] : [])
                        + (replies.map { CSSTextRun.runs($0, tags: ["strong": .bold]) } ?? [])
                    CSSText(runs: runs, style: LegacyType.body1(), wrap: .nowrap, color: gray05)
                }
                SignalIcon("v3/chevron/chevron-right", size: 16, color: Self.white, mask: true).frame(width: 16, height: 16)
            }
        } else {
            HStack(spacing: 12) {
                SignalIcon("v3/reply/reply", size: 20, color: Self.white, mask: true).frame(width: 20, height: 20)
                CSSText(i18n(data.isGroupStory ? "icu:StoryViewer__reply-group" : "icu:StoryViewer__reply"), style: LegacyType.body1(), wrap: .nowrap,
                        color: gray05)
            }
        }
    }

    @ViewBuilder var caption: some View {
        if let text = data.caption {
            let (shown, hasReadMore) = MessageBodyReadMore.slice(text, length: hasExpandedCaption ? 700 : 200, buffer: 20)
            MessageBody(text: shown, originalText: text, renderLocation: .storyViewer, style: LegacyType.body1(), linkColor: Self.white,
                        onIncreaseTextLength: hasReadMore && !hasExpandedCaption ? { hasExpandedCaption = true } : nil)
                .cssTextColor(Self.white)
            .shadow(color: Color(.sRGB, white: 0, opacity: 0.8), radius: 24)
            .padding(.vertical, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    public var body: some View {
        GeometryReader { g in
            let metaWidth = max(284, min(max(0, g.size.height * 0.5625), g.size.width))
            ZStack {
                overlay(g.size, pad: 300).blur(radius: 90).frame(width: g.size.width, height: g.size.height).clipped()
                Color(rgba: LegacyColor.blackAlpha20)
                // __protection--top
                LinearGradient(colors: [Color(rgba: LegacyColor.blackAlpha16), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80).frame(maxHeight: .infinity, alignment: .top)
                StoryImage(attachment: data.story.attachment, firstName: data.story.sender.firstName ?? data.story.sender.title, isMe: data.isMe, fitContain: true)
                    .frame(width: g.size.width, height: g.size.height)
                // __protection--bottom (taller and darker under a caption)
                LinearGradient(colors: [.clear, Color(rgba: data.caption != nil ? LegacyColor.blackAlpha80 : LegacyColor.blackAlpha60)], startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: data.caption != nil ? 280 : 140).frame(maxHeight: .infinity, alignment: .bottom)
                if hasExpandedCaption {
                    LinearGradient(colors: [.clear, Color(rgba: LegacyColor.blackAlpha40)], startPoint: .top, endPoint: .bottom)
                        .onTapGesture { hasExpandedCaption = false }
                }
                HStack(spacing: 0) {
                    arrow(.left, show: data.currentIndex > 0, width: g.size.width / 4, action: actions.viewPrevious)
                    Spacer(minLength: 0)
                    arrow(.right, show: true, width: g.size.width / 4, action: actions.viewNext)
                }
                VStack(spacing: 0) {
                    caption
                    playbackBar
                    progress
                    actionsRow
                }
                .padding(.horizontal, 16)
                .frame(width: metaWidth)
                .frame(maxHeight: .infinity, alignment: .bottom)
                Button(action: actions.onClose) {
                    SignalIcon("v3/x/x", size: 20, color: AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15), mask: true).frame(width: 20, height: 20)
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel(i18n("icu:close"))
                .padding(.top, dragAreaHeight).padding(.trailing, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .background(Color.black)
        .onExitCommand(perform: actions.onClose)
    }

    enum Side { case left, right }

    /// `StoryViewer__arrow`: a quarter of the window, its chevron shown while hovered.
    func arrow(_ side: Side, show: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SignalIcon(side == .left ? "v3/chevron/chevron-left" : "v3/chevron/chevron-right", size: 28, color: Self.white, mask: true)
                .frame(width: 28, height: 28)
                .opacity(hoveredArrow == (side == .left ? 0 : 1) ? 1 : 0)
                .padding(side == .left ? .leading : .trailing, 16)
                .frame(width: width, alignment: side == .left ? .leading : .trailing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .onHover { hoveredArrow = $0 ? (side == .left ? 0 : 1) : nil }
        .opacity(show ? 1 : 0)
        .allowsHitTesting(show)
        .accessibilityLabel(i18n(side == .left ? "icu:back" : "icu:forward"))
    }
}
