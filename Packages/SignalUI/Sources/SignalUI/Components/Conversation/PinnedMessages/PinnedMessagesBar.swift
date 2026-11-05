// Port of ts/components/conversation/pinned-messages/PinnedMessagesBar.dom.tsx: the bar of pinned
// messages under the conversation header. A 56px row (with two or more pins, a vertical tab
// strip of 2px bars to pick one) showing the current pin's thumbnail, sender (body-small
// semibold) and one-line preview, and the pin menu (unpin, go to message, see all).
//
// Payments are out of scope: a payment pin has no preview here.

import SignalI18n
import SwiftUI

/// `PinMessage` (the parts the bar shows).
public struct PinMessage: Sendable {
    public enum Attachment: Sendable { case image(RGBAImage?), video(RGBAImage?), voiceMessage, gif, file(String?) }
    public var id: String
    public var text: (body: String, bodyRanges: [BodyRange])?
    public var attachment: Attachment?
    public var contactName: String??
    public var pollQuestion: String?
    public var sticker = false
    public var viewOnceMedia = false
    public init(id: String) { self.id = id }
}

/// `Pin`
public struct Pin: Identifiable, Sendable {
    public var id: Int
    public var senderTitle: String
    public var message: PinMessage
    public init(id: Int, senderTitle: String, message: PinMessage) {
        self.id = id
        self.senderTitle = senderTitle
        self.message = message
    }
}

public struct PinnedMessagesBar: View {
    let pins: [Pin]
    @Binding var current: Int?
    let canPinMessages: Bool
    let onPinGoTo: (String) -> Void
    let onPinRemove: (String) -> Void
    let onPinsShowAll: () -> Void
    @State private var menuOpen = false
    @Environment(\.i18n) var i18n

    public init(pins: [Pin], current: Binding<Int?>, canPinMessages: Bool, onPinGoTo: @escaping (String) -> Void = { _ in },
                onPinRemove: @escaping (String) -> Void = { _ in }, onPinsShowAll: @escaping () -> Void = {}) {
        self.pins = pins
        _current = current
        self.canPinMessages = canPinMessages
        self.onPinGoTo = onPinGoTo
        self.onPinRemove = onPinRemove
        self.onPinsShowAll = onPinsShowAll
    }

    /// `getMessagePreview`: (icon symbol, text runs) in priority order.
    func preview(_ m: PinMessage) -> (AxoSymbol.Name?, [CSSTextRun]) {
        var icon: AxoSymbol.Name?
        var text: [CSSTextRun]?
        let style = CSSTextStyle(AxoType.bodyMedium)
        if m.viewOnceMedia {
            text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--ViewOnceMedia"))]
            icon = "viewonce"
        }
        if let t = m.text, text == nil {
            // stripNewlinesForLeftPane: each newline becomes as many spaces.
            let body = t.body.replacingOccurrences(of: "\r\n", with: "  ").replacingOccurrences(of: "\n", with: " ")
            text = MessageTextRenderer.runs(text: body, bodyRanges: t.bodyRanges, style: style, renderLocation: .pinnedMessagesBar,
                                            originalText: t.body, textLength: t.body.utf16.count)
        }
        if let q = m.pollQuestion {
            if text == nil { text = [Emojify.run(q)] }
            if icon == nil { icon = "poll" }
        } else if m.sticker {
            if text == nil { text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--Sticker"))] }
            if icon == nil { icon = "sticker" }
        } else if let contact = m.contactName {
            if text == nil { text = [Emojify.run(contact ?? i18n("icu:unknownContact"))] }
            if icon == nil { icon = "person-circle" }
        }
        if let a = m.attachment {
            switch a {
            case .image: if text == nil { text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--Photo"))] }
            case .video: if text == nil { text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--Video"))] }
            case .voiceMessage:
                if text == nil { text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--VoiceMessage"))] }
                if icon == nil { icon = "audio" }
            case .gif:
                if text == nil { text = [CSSTextRun(i18n("icu:PinnedMessagesBar__MessagePreview__Text--Gif"))] }
                if icon == nil { icon = "gif" }
            case .file(let name):
                if text == nil { text = [Emojify.run(name ?? "")] }
                if icon == nil { icon = "file" }
            }
        }
        return (icon, text ?? [])
    }

    /// `getThumbnailUrl`: an image or video's, never view-once media's.
    func thumbnail(_ m: PinMessage) -> RGBAImage? {
        if m.viewOnceMedia { return nil }
        switch m.attachment {
        case .image(let i), .video(let i): return i
        default: return nil
        }
    }

    func content(_ pin: Pin) -> some View {
        let (icon, runs) = preview(pin.message)
        return HStack(alignment: .center, spacing: 0) {
            if let thumb = thumbnail(pin.message) {
                PixelImage(thumb, fit: .cover).frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                CSSText(runs: [Emojify.run(pin.senderTitle)], style: CSSTextStyle(AxoType.bodySmall.weight(600)), wrap: .truncate, color: .labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let icon {
                        AxoSymbol.InlineGlyph(icon, size: 13, weight: 400)
                        CSSText(" ", style: CSSTextStyle(AxoType.bodyMedium), wrap: .nowrap)
                    }
                    CSSText(runs: runs, style: CSSTextStyle(AxoType.bodyMedium), wrap: .truncate)
                }
                .cssTextColor(.labelPrimary)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.leading, pins.count == 1 ? 16 : 0)
    }

    /// The vertical tab strip: one 2px bar per pin (label-primary when current).
    var tabs: some View {
        VStack(spacing: 0) {
            ForEach(Array(pins.enumerated()), id: \.element.id) { i, pin in
                SwiftUI.Button { current = pin.id } label: {
                    Capsule().fill(pin.id == current ? AxoColor.labelPrimary : AxoColor.labelDisabled)
                        .frame(width: 2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, pins.count == 3 ? 1 : 2)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n("icu:PinnedMessagesBar__Tab__AccessibilityLabel", ["pinNumber": .number(Double(i + 1))]))
            }
        }
        .padding(.vertical, 10)
    }

    public var body: some View {
        if !pins.isEmpty, let pin = pins.first(where: { $0.id == current }) {
            HStack(alignment: .center, spacing: 0) {
                if pins.count >= 2 { tabs }
                content(pin)
                    .contentShape(Rectangle())
                    .onTapGesture { onPinGoTo(pin.message.id) }
                AxoDropdownMenu.Root(isOpen: $menuOpen) {
                    AxoIconButton.Root(label: i18n("icu:PinnedMessagesBar__ActionsMenu__Button__AccessibilityLabel"), variant: .impliedSecondary,
                                       size: .md, symbol: "pin")
                } items: {
                    if canPinMessages {
                        AxoDropdownMenu.Item(i18n("icu:PinnedMessagesBar__ActionsMenu__UnpinMessage"), symbol: "pin-slash") { onPinRemove(pin.message.id) }
                    }
                    AxoDropdownMenu.Item(i18n("icu:PinnedMessagesBar__ActionsMenu__GoToMessage"), symbol: "message-arrow-forward") { onPinGoTo(pin.message.id) }
                    AxoDropdownMenu.Item(i18n("icu:PinnedMessagesBar__ActionsMenu__SeeAllMessages"), symbol: "list-bullet", action: onPinsShowAll)
                }
            }
            .padding(.trailing, 12)
            .frame(height: 56)
            // border-t-[0.5px] border-t-primary (drawn a whole CSS pixel), legacy header background
            .padding(.top, 1)
            .background(AxoColor.legacyConversationHeaderBg)
            .overlay(alignment: .top) { Rectangle().fill(AxoColor.borderPrimary).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(i18n("icu:PinnedMessagesBar__AccessibilityLabel", ["pinsCount": .number(Double(pins.count))]))
        }
    }
}
