// MessageBody (ts/components/conversation/MessageBody.dom.tsx + stylesheets/components/
// MessageBody.scss): an optional author ("Name: ") and prefix, the message text through
// MessageTextRenderer (links only when `shouldLinkifyMessage`, jumbomoji for 1–5 emoji-only
// texts), then the end notification: "Read more", "Downloading", "Download Full Message" or
// "Message too long to display more" (all bold; the text gets a "..." suffix first).
//
// Subset: the author is body-2-medium's weight in the paragraph's size (runs share one size).

import SignalI18n
import SignalText
import SwiftUI

/// The `textAttachment` fields MessageBody reads (`pending`, downloadability, `wasTooBig`).
public struct MessageBodyTextAttachment: Sendable, Hashable {
    public var pending: Bool
    /// `canBeDownloaded(textAttachment) && !isDownloaded(textAttachment)`
    public var canDownload: Bool
    public var wasTooBig: Bool
    public init(pending: Bool = false, canDownload: Bool = false, wasTooBig: Bool = false) {
        self.pending = pending
        self.canDownload = canDownload
        self.wasTooBig = wasTooBig
    }
}

public struct MessageBody: View {
    let author: String?
    let bodyRanges: [BodyRange]
    let direction: MessageDirection?
    let disableJumbomoji: Bool
    let disableLinks: Bool
    let isSpoilerExpanded: [Int: Bool]
    let kickOffBodyDownload: (() -> Void)?
    let onExpandSpoiler: (([Int: Bool]) -> Void)?
    let onIncreaseTextLength: (() -> Void)?
    let prefix: String?
    let renderLocation: RenderLocation
    let showConversation: ((String) -> Void)?
    let text: String
    let textAttachment: MessageBodyTextAttachment?
    let originalText: String
    let style: CSSTextStyle
    let wrap: CSSTextWrap
    let linkColor: AxoColor?
    /// MessageTextMetadataSpacer: room for the inline metadata (its width + 10) at the end.
    let metadataSpacer: CGFloat?
    let alignment: CSSTextAlign
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(text: String, originalText: String? = nil, bodyRanges: [BodyRange] = [], author: String? = nil, prefix: String? = nil,
                direction: MessageDirection? = nil, disableJumbomoji: Bool = false, disableLinks: Bool = false,
                renderLocation: RenderLocation, isSpoilerExpanded: [Int: Bool] = [:], textAttachment: MessageBodyTextAttachment? = nil,
                style: CSSTextStyle = CSSTextStyle(AxoType.bodyLarge), wrap: CSSTextWrap = .wrap, linkColor: AxoColor? = nil,
                metadataSpacer: CGFloat? = nil, alignment: CSSTextAlign = .start,
                kickOffBodyDownload: (() -> Void)? = nil, onExpandSpoiler: (([Int: Bool]) -> Void)? = nil,
                onIncreaseTextLength: (() -> Void)? = nil, showConversation: ((String) -> Void)? = nil) {
        self.author = author
        self.bodyRanges = bodyRanges
        self.direction = direction
        self.disableJumbomoji = disableJumbomoji
        self.disableLinks = disableLinks
        self.isSpoilerExpanded = isSpoilerExpanded
        self.kickOffBodyDownload = kickOffBodyDownload
        self.onExpandSpoiler = onExpandSpoiler
        self.onIncreaseTextLength = onIncreaseTextLength
        self.prefix = prefix
        self.renderLocation = renderLocation
        self.showConversation = showConversation
        self.text = text
        self.textAttachment = textAttachment
        self.originalText = originalText ?? text
        self.style = style
        self.wrap = wrap
        self.linkColor = linkColor
        self.metadataSpacer = metadataSpacer
        self.alignment = alignment
    }

    /// `dir="auto"`: the paragraph direction of `text` (its first strong character), nil if none.
    public static func firstStrongDirection(_ text: String) -> SwiftUI.LayoutDirection? {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) { return .rightToLeft }
            if scalar.properties.isAlphabetic { return .leftToRight }
        }
        return nil
    }

    /// `getSizeClass`: FunJumboEmojiSize for 1–5 emoji (whitespace ignored), else nil.
    public static func jumboEmojiSize(_ text: String) -> CGFloat? {
        switch jumboEmojiCount(text) {
        case 1: 56
        case 2: 48
        case 3: 40
        case 4: 36
        case 5: 32
        default: nil
        }
    }

    /// `Emoji.getJumboEmojiCount`: the number of emoji in an emoji-only text (at most 5).
    public static func jumboEmojiCount(_ text: String) -> Int? {
        var count = 0
        for ch in text {
            if ch.isWhitespace { continue }
            guard CSSTextLayout.isEmoji(ch) else { return nil }
            count += 1
            if count > 5 { return nil }
        }
        return count == 0 ? nil : count
    }

    var runs: [CSSTextRun] {
        var out: [CSSTextRun] = []
        if let author, !author.isEmpty {
            var r = CSSTextRun(author, fontName: AxoFonts.interName(weight: 500))   // .MessageBody__author
            r.emojify = true
            out.append(r)
            out.append(CSSTextRun(": "))
        }
        if let prefix, !prefix.isEmpty {
            var r = CSSTextRun(prefix + " ")
            r.emojify = true
            out.append(r)
        }
        let suffixed = textAttachment?.pending == true || onIncreaseTextLength != nil || textAttachment?.wasTooBig == true
        let shouldDisableLinks = disableLinks || !LinkPreviewRules.shouldLinkifyMessage(originalText)
        out += MessageTextRenderer.runs(text: suffixed ? text + "..." : text, bodyRanges: bodyRanges, style: style,
                                        renderLocation: renderLocation, direction: direction, disableLinks: shouldDisableLinks,
                                        jumboEmojiSize: disableJumbomoji ? nil : Self.jumboEmojiSize(text), originalText: originalText,
                                        textLength: BodyRanges.utf16Length(text), linkColor: linkColor,
                                        isSpoilerExpanded: isSpoilerExpanded)
        let bold = AxoFonts.interName(weight: 700)
        if onIncreaseTextLength != nil {
            // A <button> (inline-block): its leading space collapses and it does not wrap inside.
            out.append(.inlineBlock(i18n("icu:MessageBody--read-more"), CSSInlineBlock(paddingInline: 0), fontName: bold))
            out[out.count - 1].action = MessageTextAction.readMore.encoded
        } else if textAttachment?.pending == true {
            out.append(CSSTextRun(" " + i18n("icu:downloading"), fontName: bold))       // .MessageBody__highlight
        } else if let t = textAttachment, t.canDownload, kickOffBodyDownload != nil {
            out.append(CSSTextRun(" "))
            out.append(CSSTextRun(i18n("icu:downloadFullMessage"), fontName: bold, action: MessageTextAction.downloadBody.encoded))
        } else if textAttachment?.wasTooBig == true {
            out.append(CSSTextRun(" " + i18n("icu:MessageBody--message-too-long"), fontName: bold))
        }
        out = CSSTextRun.collapsingWhiteSpace(out)
        if let w = metadataSpacer {
            // An inline-block after the text: a break opportunity before it (U+200B), no content.
            out.append(CSSTextRun("\u{200B}"))
            out.append(.inlineBlock("", CSSInlineBlock(paddingInline: (w + 10) / 2)))
        }
        return out
    }

    /// The live timeline makes message text selectable (`\.messageTextSelectable`).
    @Environment(\.messageTextSelectable) var textSelectable

    public var body: some View {
        CSSText(runs: runs, style: style, wrap: wrap, alignment: alignment, onTap: { handle(MessageTextAction(encoded: $0)) })
            .environment(\.cssTextSelectable, textSelectable)
    }

    func handle(_ action: MessageTextAction) {
        switch action {
        case .link(let url): if let u = URL(string: url) { openURL(u) }
        case .mention(let id): showConversation?(id)
        case .expandSpoiler(let id):
            var expanded = isSpoilerExpanded
            expanded[id] = true
            onExpandSpoiler?(expanded)
        case .readMore: onIncreaseTextLength?()
        case .downloadBody: kickOffBodyDownload?()
        }
    }
}

extension EnvironmentValues {
    /// Message bodies can be selected with the mouse and copied (the app's live timeline;
    /// off in static renders).
    @Entry public var messageTextSelectable = false
}
