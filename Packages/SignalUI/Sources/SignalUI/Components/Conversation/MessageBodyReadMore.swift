// MessageBodyReadMore (ts/components/conversation/MessageBodyReadMore.dom.tsx): MessageBody cut
// to `displayLimit` (800) UTF-16 units at a grapheme boundary (graphemeAndLinkAwareSlice: not
// below 900, and never inside a link), with "Read more" adding 3000 more.

import SwiftUI

public struct MessageBodyReadMore: View {
    static let initialLength = 800
    static let incrementCount = 3000
    static let buffer = 100

    let text: String
    let bodyRanges: [BodyRange]
    let direction: MessageDirection?
    let disableLinks: Bool
    let displayLimit: Int?
    let isSpoilerExpanded: [Int: Bool]
    let renderLocation: RenderLocation
    let textAttachment: MessageBodyTextAttachment?
    let style: CSSTextStyle
    let linkColor: AxoColor?
    let metadataSpacer: CGFloat?
    let alignment: CSSTextAlign
    let messageExpanded: (Int) -> Void
    let kickOffBodyDownload: (() -> Void)?
    let onExpandSpoiler: (([Int: Bool]) -> Void)?
    let showConversation: ((String) -> Void)?

    public init(text: String, bodyRanges: [BodyRange] = [], direction: MessageDirection? = nil, disableLinks: Bool = false,
                displayLimit: Int? = nil, isSpoilerExpanded: [Int: Bool] = [:], renderLocation: RenderLocation,
                textAttachment: MessageBodyTextAttachment? = nil, style: CSSTextStyle = CSSTextStyle(AxoType.bodyLarge),
                linkColor: AxoColor? = nil, metadataSpacer: CGFloat? = nil, alignment: CSSTextAlign = .start,
                messageExpanded: @escaping (Int) -> Void, kickOffBodyDownload: (() -> Void)? = nil,
                onExpandSpoiler: (([Int: Bool]) -> Void)? = nil, showConversation: ((String) -> Void)? = nil) {
        self.text = text
        self.bodyRanges = bodyRanges
        self.direction = direction
        self.disableLinks = disableLinks
        self.displayLimit = displayLimit
        self.isSpoilerExpanded = isSpoilerExpanded
        self.renderLocation = renderLocation
        self.textAttachment = textAttachment
        self.style = style
        self.linkColor = linkColor
        self.metadataSpacer = metadataSpacer
        self.alignment = alignment
        self.messageExpanded = messageExpanded
        self.kickOffBodyDownload = kickOffBodyDownload
        self.onExpandSpoiler = onExpandSpoiler
        self.showConversation = showConversation
    }

    /// `doesMessageBodyOverflow`
    public static func doesOverflow(_ text: String) -> Bool { BodyRanges.utf16Length(text) > initialLength + buffer }

    /// `graphemeAndLinkAwareSlice`
    public static func slice(_ str: String, length: Int, buffer: Int = 100) -> (text: String, hasReadMore: Bool) {
        let total = BodyRanges.utf16Length(str)
        guard total > length + buffer else { return (str, false) }
        var cut: Int?
        var index = 0
        for ch in str {
            if cut == nil, index >= length { cut = index }
            if let c = cut, index > length {
                var end = c
                // expandToIncludeEntireLink
                if let link = LinkifyIt.match(str).first(where: { $0.index < end && $0.lastIndex > end }) { end = link.lastIndex }
                return (BodyRanges.slice(str, 0, end), end < total)
            }
            index += ch.utf16.count
        }
        return (str, false)
    }

    public var body: some View {
        let maxLength = displayLimit ?? Self.initialLength
        let (sliced, hasReadMore) = Self.slice(text, length: maxLength, buffer: Self.buffer)
        MessageBody(text: sliced, originalText: text, bodyRanges: bodyRanges, direction: direction, disableJumbomoji: !bodyRanges.isEmpty,
                    disableLinks: disableLinks || !LinkPreviewRules.shouldLinkifyMessage(text), renderLocation: renderLocation,
                    isSpoilerExpanded: isSpoilerExpanded, textAttachment: textAttachment, style: style, linkColor: linkColor,
                    metadataSpacer: metadataSpacer, alignment: alignment,
                    kickOffBodyDownload: kickOffBodyDownload, onExpandSpoiler: onExpandSpoiler,
                    onIncreaseTextLength: hasReadMore ? { messageExpanded(maxLength + Self.incrementCount) } : nil,
                    showConversation: showConversation)
    }
}
