// MessageMetadata (ts/components/conversation/MessageMetadata.dom.tsx + `.module-message__metadata`):
// a bubble's bottom-end line in font-caption — pinned glyph, "Edited", the time (or the send
// error / paused / partially-sent text), the SMS lock, the disappearing timer, the pending
// spinner and the outgoing status icon. Inline (floated onto the text's last line) or at the
// bottom; over an uncaptioned image it is white on the image.

import SignalI18n
import SwiftUI

/// `MessageStatusType`
public enum MessageStatus: String, Sendable, Hashable {
    case delivered, error, paused, partialSent = "partial-sent", read, sending, sent, viewed
}

public struct MessageMetadata: View {
    let direction: MessageDirection
    let timestamp: Date
    let status: MessageStatus?
    let expiration: (length: TimeInterval, timestamp: Date?)?
    let isPinned: Bool
    let isEdited: Bool
    let isSMS: Bool
    let deletedForEveryone: Bool
    let canRetryDeleteForEveryone: Bool
    let isOutlineOnlyBubble: Bool
    let isSticker: Bool
    let withImageNoCaption: Bool
    let textPending: Bool
    let actions: Actions
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    public struct Actions {
        public var showEditHistory: (() -> Void)?
        public var retryMessageSend: () -> Void = {}
        public var retryDeleteForEveryone: () -> Void = {}
        public var showMessageDetails: () -> Void = {}
        public init() {}
    }

    public init(direction: MessageDirection, timestamp: Date, status: MessageStatus? = nil, expiration: (length: TimeInterval, timestamp: Date?)? = nil,
                isPinned: Bool = false, isEdited: Bool = false, isSMS: Bool = false, deletedForEveryone: Bool = false,
                canRetryDeleteForEveryone: Bool = false, isOutlineOnlyBubble: Bool = false, isSticker: Bool = false, withImageNoCaption: Bool = false,
                textPending: Bool = false, actions: Actions = Actions()) {
        self.direction = direction
        self.timestamp = timestamp
        self.status = status
        self.expiration = expiration
        self.isPinned = isPinned
        self.isEdited = isEdited
        self.isSMS = isSMS
        self.deletedForEveryone = deletedForEveryone
        self.canRetryDeleteForEveryone = canRetryDeleteForEveryone
        self.isOutlineOnlyBubble = isOutlineOnlyBubble
        self.isSticker = isSticker
        self.withImageNoCaption = withImageNoCaption
        self.textPending = textPending
        self.actions = actions
    }

    static var style: CSSTextStyle { LegacyType.caption() }

    var color: AxoColor {
        if withImageNoCaption { return AxoColor(light: LegacyColor.white, dark: LegacyColor.whiteAlpha80) }
        if isOutlineOnlyBubble || isSticker { return AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }
        return direction == .outgoing ? .labelSecondaryOncolor : .labelSecondary
    }

    /// The time, or the error / paused / partial text in its place.
    var timestampText: (String, (() -> Void)?) { timestampText(i18n: i18n, now: fixedNow ?? .now, timeZone: timeZone) }

    func timestampText(i18n: Localizer, now: Date, timeZone: TimeZone) -> (String, (() -> Void)?) {
        let outgoingOrDelete = direction == .outgoing || deletedForEveryone
        if status == .error && outgoingOrDelete {
            if deletedForEveryone && canRetryDeleteForEveryone { return (i18n("icu:deleteFailedClickForDetails"), actions.retryDeleteForEveryone) }
            if deletedForEveryone { return (i18n("icu:deleteFailed"), nil) }
            if isEdited { return (i18n("icu:editFailed"), actions.retryMessageSend) }
            return (i18n("icu:sendFailed"), nil)
        }
        if status == .paused { return (i18n("icu:sendPaused"), nil) }
        if status == .partialSent && outgoingOrDelete {
            return (i18n(deletedForEveryone ? "icu:partiallyDeleted--clickForDetails" : "icu:partiallySent"), actions.showMessageDetails)
        }
        return (FormatTimestamp.time(timestamp, now: now, i18n: i18n, timeZone: timeZone), nil)
    }

    /// An outgoing message without a status still renders `.module-message__metadata__status-icon`
    /// (16px, margin-inline-start 8), empty.
    var hasEmptyStatusIcon: Bool { direction == .outgoing && status == nil && !deletedForEveryone && !textPending }

    var statusIcon: (String, CGFloat, CGFloat)? {
        // (icon, width, trailing margin)
        guard direction == .outgoing, let status else { return nil }
        switch status {
        case .sending, .paused: return ("v3/message_status/messagestatus-sending", 12, 6)
        case .sent: return ("v3/message_status/messagestatus-sent", 12, 6)
        case .delivered: return ("v3/message_status/messagestatus-delivered", 18, 0)
        case .read, .viewed: return ("v3/message_status/messagestatus-read", 18, 0)
        case .error, .partialSent: return nil
        }
    }

    /// The metadata's width (for the inline spacer in the message text), from the same pieces.
    /// The caller passes its environment: this view is not in the hierarchy yet.
    @MainActor func width(i18n: Localizer, now: Date, timeZone: TimeZone) -> CGFloat {
        let style = Self.style
        func text(_ t: String) -> CGFloat { CSSTextLayout.make(t, style, wrap: .nowrap, maxWidth: nil).width }
        func glyph(_ name: AxoSymbol.Name) -> CGFloat {
            CSSTextLayout.make(String(AxoSymbol.inlineGlyph(name)), AxoSymbol.style(size: style.size, weight: 400), wrap: .nowrap, maxWidth: nil).width
        }
        var w = text(timestampText(i18n: i18n, now: now, timeZone: timeZone).0)
        if isPinned { w += glyph("pin-fill") + 4 }
        if isEdited && actions.showEditHistory != nil { w += text(i18n("icu:MessageMetadata__edited")) + 6 }
        if isSMS { w += glyph("lock-open") + 6 }
        if let expiration, expiration.length > 0 { w += 18 }
        if textPending { w += 20 }
        if let (_, iconWidth, trailing) = statusIcon { w += 6 + iconWidth + trailing }
        if hasEmptyStatusIcon { w += 8 + 16 }
        return w
    }

    public var body: some View {
        let style = Self.style
        HStack(alignment: .center, spacing: 0) {
            if isPinned {
                AxoSymbol.InlineGlyph("pin-fill", size: style.size, weight: 400).padding(.trailing, 4)
                    .accessibilityLabel(i18n("icu:MessageMetadata__pinned"))
            }
            if isEdited, let show = actions.showEditHistory {
                SwiftUI.Button(action: show) { CSSText(i18n("icu:MessageMetadata__edited"), style: style, wrap: .nowrap) }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
            }
            let (text, tap) = timestampText
            Group {
                if let tap {
                    SwiftUI.Button(action: tap) { CSSText(text, style: style, wrap: .nowrap) }.buttonStyle(.plain)
                } else {
                    CSSText(text, style: style, wrap: .nowrap)
                }
            }
            if isSMS {
                AxoSymbol.InlineGlyph("lock-open", size: style.size, weight: 400).padding(.leading, 6)
            }
            if let expiration, expiration.length > 0 {
                ExpireTimer(expirationLength: expiration.length, expirationTimestamp: expiration.timestamp)
                    .padding(.leading, 6).padding(.bottom, 2)
            }
            if textPending {
                Spinner(svgSize: .small, direction: direction == .outgoing ? .onBackground : .onBackground, size: 14).padding(.leading, 6)
            }
            if let (icon, width, trailing) = statusIcon {
                SignalIcon(icon, color: withImageNoCaption ? AxoColor(light: LegacyColor.white, dark: LegacyColor.gray02) : color)
                    .frame(width: width, height: 12)
                    .padding(.leading, 6).padding(.trailing, trailing).padding(.bottom, 2)
            } else if hasEmptyStatusIcon {
                Color.clear.frame(width: 16, height: 16).padding(.leading, 8)
            }
        }
        .frame(height: style.lineHeight)
        .cssTextColor(color)
        .fixedSize()
    }
}
