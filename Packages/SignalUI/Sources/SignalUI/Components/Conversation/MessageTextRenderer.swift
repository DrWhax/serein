// MessageTextRenderer (ts/components/conversation/MessageTextRenderer.dom.tsx,
// stylesheets/components/MessageTextRenderer.scss): message text with its body ranges and
// links as CSSText runs. Bold and keyword highlights are <strong>, italic <em>, strikethrough
// <s>, monospace Menlo, hidden spoilers transparent text on a rounded block.
// Mentions are AtMention pills (an inline-block), or "@Name" when links are disabled. Links
// are `<a>`s (the UA's underlined link colour unless `linkColor` is given). Emoji go through
// Emojify, at `jumboEmojiSize` outside mentions.
//
// Taps resolve to a `MessageTextAction` (CSSText runs carry it as their action string).

import SwiftUI

/// `RenderLocation`
public enum RenderLocation: Sendable { case conversationList, quote, mediaEditor, pinnedMessagesBar, searchResult, storyViewer, timeline }

/// What a tap on a message text run does.
public enum MessageTextAction: Sendable, Hashable {
    case link(String)
    case mention(conversationID: String)
    case expandSpoiler(Int)
    case readMore
    case downloadBody

    static let prefix = "\u{0}signalsafe:"

    var encoded: String {
        switch self {
        case .link(let url): return url
        case .mention(let id): return Self.prefix + "mention:" + id
        case .expandSpoiler(let id): return Self.prefix + "spoiler:\(id)"
        case .readMore: return Self.prefix + "read-more"
        case .downloadBody: return Self.prefix + "download-body"
        }
    }

    init(encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { self = .link(encoded); return }
        let rest = String(encoded.dropFirst(Self.prefix.count))
        if rest.hasPrefix("mention:") { self = .mention(conversationID: String(rest.dropFirst(8))) }
        else if rest.hasPrefix("spoiler:") { self = .expandSpoiler(Int(rest.dropFirst(8)) ?? 0) }
        else if rest == "read-more" { self = .readMore }
        else { self = .downloadBody }
    }
}

public enum MessageTextRenderer {
    /// The runs for `text` with `bodyRanges` (already hydrated mentions), in `style`.
    /// - Parameters:
    ///   - originalText: the full text links are found in (`text` may be truncated); default `text`.
    ///   - textLength: the displayed length before any suffix (ranges past it are dropped).
    public static func runs(text: String, bodyRanges: [BodyRange], style: CSSTextStyle, renderLocation: RenderLocation,
                            direction: MessageDirection? = nil, disableLinks: Bool = true, jumboEmojiSize: CGFloat? = nil,
                            originalText: String? = nil, textLength: Int? = nil, linkColor: AxoColor? = nil,
                            isSpoilerExpanded: [Int: Bool] = [:]) -> [CSSTextRun] {
        let length = textLength ?? BodyRanges.utf16Length(text)
        let links = disableLinks ? [] : extractLinks(originalText ?? text, displayedTextLength: length)
        // Spoilers are numbered in order; mentions sort after the other ranges.
        var spoilerCount = 0
        var prepared: [BodyRange] = []
        for range in bodyRanges.sorted(by: { ($0.isMention ? 1 : 0) < ($1.isMention ? 1 : 0) }) {
            if case .formatting(.spoiler, _) = range.kind {
                spoilerCount += 1
                prepared.append(BodyRange(start: range.start, length: range.length, kind: .formatting(.spoiler, spoilerId: spoilerCount)))
            } else if range.start < length {
                prepared.append(range)
            }
        }
        let nodes = BodyRanges.groupContiguousSpoilers(BodyRanges.collapseToDisplayNodes(text, links + prepared))
        let context = Context(style: style, direction: direction, disableLinks: disableLinks, jumboEmojiSize: jumboEmojiSize,
                              linkColor: linkColor, linksBreakAll: renderLocation == .timeline)
        var out: [CSSTextRun] = []
        for node in nodes {
            if node.isSpoiler, let children = node.spoilerChildren, !children.isEmpty {
                let id = node.spoilerId ?? 0
                let hidden = !(isSpoilerExpanded[id] ?? false)
                let first = out.count
                for child in children { out += nodeRuns(child, context, invisible: hidden) }
                if hidden {
                    // The spoiler span: opacity 50%, radius 4, transparent text; a tap reveals it.
                    for i in first..<out.count {
                        if let color = spoilerColor(renderLocation, direction) {
                            out[i].background = color
                            out[i].backgroundRadius = 4
                        }
                        out[i].action = disableLinks ? nil : MessageTextAction.expandSpoiler(id).encoded
                    }
                }
            } else {
                out += nodeRuns(node, context, invisible: false)
            }
        }
        return out
    }

    struct Context {
        let style: CSSTextStyle
        let direction: MessageDirection?
        let disableLinks: Bool
        let jumboEmojiSize: CGFloat?
        let linkColor: AxoColor?
        /// `.module-message__text a { word-break: break-all }` (timeline bubbles).
        var linksBreakAll = false
    }

    static func nodeRuns(_ node: DisplayNode, _ c: Context, invisible: Bool) -> [CSSTextRun] {
        let bold = node.isBold || node.isKeywordHighlight
        var fontName: String?
        if node.isMonospace {
            fontName = AxoFonts.monospaceName(weight: bold ? 700 : c.style.weight, italic: node.isItalic)
        } else if bold || node.isItalic {
            fontName = AxoFonts.interName(weight: bold ? 700 : c.style.weight, italic: node.isItalic)
        }
        let transparent = AxoColor(RGBA(0, 0, 0, 0))
        let isLink = node.url.map { LinkPreviewRules.isSupportedProtocol($0) && LinkPreviewRules.isLinkSneaky($0) != .yes } ?? false
        var color: AxoColor? = node.isKeywordHighlight ? AxoColor(light: LegacyColor.black, dark: LegacyColor.white) : nil
        if isLink { color = c.linkColor ?? uaLinkColor }
        if invisible { color = transparent }
        func decorate(_ r: inout CSSTextRun) {
            r.strikethrough = node.isStrikethrough
            if isLink, let url = node.url {
                r.action = MessageTextAction.link(url).encoded
                r.underline = !invisible          // UA <a>, and `.module-message__text a { text-decoration: underline }`
                r.breakAll = c.linksBreakAll
            }
        }
        func run(_ text: String) -> CSSTextRun {
            var r = CSSTextRun(text, fontName: fontName, color: color)
            r.emojify = true
            r.emojiSize = c.jumboEmojiSize
            decorate(&r)
            return r
        }
        var result: [CSSTextRun] = []
        var offset = 0
        for m in node.mentions {
            if m.start > offset { result.append(run(BodyRanges.slice(node.text, offset, m.start))) }
            if case let .mention(_, conversationID, name) = m.kind {
                if c.disableLinks {
                    // <bdi>@<Emojify/></bdi>
                    var r = CSSTextRun("@" + name, fontName: fontName, color: color)
                    r.emojify = true
                    decorate(&r)
                    result.append(r)
                } else {
                    var r = CSSTextRun.inlineBlock("@" + name, mentionBox(c.direction, invisible: invisible), fontName: fontName, color: color)
                    r.emojify = true
                    decorate(&r)
                    if !invisible { r.action = MessageTextAction.mention(conversationID: conversationID).encoded }
                    result.append(r)
                }
            }
            offset = m.start + m.length
        }
        let rest = BodyRanges.slice(node.text, offset, node.length)
        if !rest.isEmpty || result.isEmpty { result.append(run(rest)) }
        return result
    }

    /// `.MessageBody__at-mention` (radius 4, padding-inline 4, 1px transparent border):
    /// gray-20 / black-alpha-40; incoming gray-20 / gray-60; outgoing black-alpha-40.
    /// `--invisible` (in a hidden spoiler) keeps the box and hides it.
    static func mentionBox(_ direction: MessageDirection?, invisible: Bool) -> CSSInlineBlock {
        let background: AxoColor? = switch direction {
        case .incoming: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray60)
        case .outgoing: AxoColor(LegacyColor.blackAlpha40)
        case nil: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.blackAlpha40)
        }
        return invisible ? CSSInlineBlock(paddingInline: 4, border: 1, radius: 4)
            : CSSInlineBlock(paddingInline: 4, border: 1, background: background, radius: 4)
    }

    /// `--spoiler-<location>` background at the span's 50% opacity.
    static func spoilerColor(_ location: RenderLocation, _ direction: MessageDirection?) -> AxoColor? {
        func half(_ c: AxoColor) -> AxoColor {
            AxoColor(light: RGBA(c.light.r, c.light.g, c.light.b, c.light.a * 0.5), dark: RGBA(c.dark.r, c.dark.g, c.dark.b, c.dark.a * 0.5))
        }
        switch location {
        case .storyViewer: return half(AxoColor(LegacyColor.white))
        case .mediaEditor: return half(AxoColor(LegacyColor.gray15))
        case .conversationList, .searchResult, .pinnedMessagesBar: return half(AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
        case .quote: return half(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
        case .timeline:
            switch direction {
            case .incoming: return half(AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
            case .outgoing: return half(AxoColor(RGBA(1, 1, 1, 0.9)))
            case nil: return nil
            }
        }
    }
}

/// Linkify.uaLinkColor (nonisolated here).
let uaLinkColor = AxoColor(light: RGBA(3 / 255, 15 / 255, 252 / 255), dark: RGBA(153 / 255, 161 / 255, 1))

public enum MessageDirection: Sendable { case incoming, outgoing }
