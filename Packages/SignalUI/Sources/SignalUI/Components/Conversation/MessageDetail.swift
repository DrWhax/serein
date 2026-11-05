// Port of ts/components/conversation/MessageDetail.dom.tsx (+ stylesheets/components/
// MessageDetail.scss): the message-details panel. The message itself (static, wide
// breakpoint) in a list card; a card with any errors, "Sent" (with a copy-timestamp action),
// "Received" (incoming), "Disappears in"; "View edits" for edited messages; then the
// recipients grouped by send status (From / Not sent / Viewed by / Read by / Delivered to /
// Sent to / Pending), each group titled with its status glyph and sorted by title.
//
// Avatar badges are not drawn (donor badges are out of scope).

import SignalI18n
import SwiftUI

/// `SendStatus` (ts/messages/MessageSendState.std.ts), the visible states.
public enum SendStatus: String, Sendable, Hashable, CaseIterable {
    case failed = "Failed", pending = "Pending", sent = "Sent", delivered = "Delivered", read = "Read", viewed = "Viewed"
}

/// `Contact` in MessageDetail: a recipient (or, with no status, the sender).
public struct MessageDetailContact: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var status: SendStatus?
    public var statusTimestamp: Date?
    public var isOutgoingKeyError = false
    public var isUnidentifiedDelivery = false
    public var errors: [String] = []

    public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, status: SendStatus?, statusTimestamp: Date? = nil) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
        self.status = status
        self.statusTimestamp = statusTimestamp
    }
}

public struct MessageDetail: View {
    let message: MessageProps
    let contacts: [MessageDetailContact]
    let errors: [String]
    let sentAt: Date
    let receivedAt: Date?
    let expirationTimestamp: Date?
    let isEditedMessage: Bool
    let showEditHistoryModal: (String) -> Void
    let toggleSafetyNumberModal: (String) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone
    @Environment(\.viewportWidth) var viewportWidth

    public init(message: MessageProps, contacts: [MessageDetailContact], errors: [String] = [], sentAt: Date, receivedAt: Date?,
                expirationTimestamp: Date? = nil, isEditedMessage: Bool = false, showEditHistoryModal: @escaping (String) -> Void = { _ in },
                toggleSafetyNumberModal: @escaping (String) -> Void = { _ in }) {
        self.message = message
        self.contacts = contacts
        self.errors = errors
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.expirationTimestamp = expirationTimestamp
        self.isEditedMessage = isEditedMessage
        self.showEditHistoryModal = showEditHistoryModal
        self.toggleSafetyNumberModal = toggleSafetyNumberModal
    }

    var now: Date { fixedNow ?? .now }

    func long(_ date: Date) -> String { FormatTimestamp.dateTimeLong(date, now: now, i18n: i18n, timeZone: timeZone) }

    public var body: some View {
        AxoContainer.Root {
            AxoList.Group {
                AxoList.Root {
                    AxoList.Body {
                        // containerWidthBreakpoint Wide: the bubble's max width is 50vw.
                        Message(props: message)
                            .environment(\.messageContainerMaxWidth, (viewportWidth ?? 1200) / 2)
                    }
                }
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            ForEach(errors.indices, id: \.self) { i in
                                AxoTextItem.Root(variant: .destructive, label: i18n("icu:error"), description: errors[i])
                            }
                            AxoTextItem.Root(label: i18n("icu:sent"), description: long(sentAt)) {
                                AxoItem.IconAction(label: i18n("icu:StoryDetailsModal__copy-timestamp"), variant: .impliedSecondary, symbol: "copy") {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(String(Int64(sentAt.timeIntervalSince1970 * 1000)), forType: .string)
                                }
                            }
                            if let receivedAt, receivedAt.timeIntervalSince1970 > 0, message.direction == .incoming {
                                AxoTextItem.Root(label: i18n("icu:received"), description: long(receivedAt))
                            }
                            if let expirationTimestamp, expirationTimestamp > now {
                                AxoTextItem.Root(label: i18n("icu:MessageDetail--disappears-in"),
                                                 description: ExpirationTimer.format(i18n, Int(expirationTimestamp.timeIntervalSince(now)), largest: 2))
                            }
                        }
                    }
                }
                if isEditedMessage {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group {
                                AxoClickableItem.Root(symbol: "pencil", label: i18n("icu:MessageDetail__view-edits")) { showEditHistoryModal(message.id) }
                            }
                        }
                    }
                }
                ForEach(Self.groupOrder, id: \.self) { status in
                    let group = contacts.filter { $0.status == status }
                    if !group.isEmpty { contactGroup(status, group) }
                }
            }
        }
    }

    /// The groups in upstream's order; nil is the sender ("From").
    static let groupOrder: [SendStatus?] = [nil, .failed, .viewed, .read, .delivered, .sent, .pending]

    func title(_ status: SendStatus?) -> String {
        switch status {
        case nil: i18n("icu:from")
        case .failed: i18n("icu:MessageDetailsHeader--Failed")
        case .pending: i18n("icu:MessageDetailsHeader--Pending")
        case .sent: i18n("icu:MessageDetailsHeader--Sent")
        case .delivered: i18n("icu:MessageDetailsHeader--Delivered")
        case .read: i18n("icu:MessageDetailsHeader--Read")
        case .viewed: i18n("icu:MessageDetailsHeader--Viewed")
        }
    }

    static func symbol(_ status: SendStatus?) -> AxoSymbol.Name? {
        switch status {
        case nil: nil
        case .failed: "error-circle"
        case .pending: "circle-dashed"      // animate-spin (still under reduced motion)
        case .sent: "check-circle"
        case .delivered: "check-circle-on-check-circle"
        case .read, .viewed: "check-circle-on-check-circle-fill"
        }
    }

    func contactGroup(_ status: SendStatus?, _ group: [MessageDetailContact]) -> some View {
        // Intl.Collator().compare
        let sorted = group.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var pieces: [AxoInlinePiece] = [.text(title(status))]
        if let symbol = Self.symbol(status) { pieces += [.text("\u{00A0}"), .glyph(AxoSymbol.inlineGlyph(symbol))] }
        return AxoContactList.Root(titlePieces: pieces) {
            ForEach(sorted) { contact in contactItem(contact) }
        }
    }

    func contactItem(_ contact: MessageDetailContact) -> some View {
        AxoContactList.Item(title: contact.title, valueView: AnyView(value(contact))) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 32, conversationType: .direct, color: contact.color,
                   image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
        } description: {
            if !contact.errors.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contact.errors.indices, id: \.self) { i in
                        AxoContactList.DescriptionText(contact.errors[i]).cssTextColor(.labelDestructive)
                    }
                }
            }
        } accessory: {
            if contact.isOutgoingKeyError {
                AxoContactList.ItemAction(i18n("icu:showSafetyNumber"), variant: .subtleSecondary) { toggleSafetyNumberModal(contact.id) }
            }
        }
    }

    /// The sealed-sender icon (18px, 6px before the time) and the status time.
    func value(_ contact: MessageDetailContact) -> some View {
        HStack(alignment: .center, spacing: 0) {
            if contact.isUnidentifiedDelivery {
                IconInheritingColor(name: "v2/unidentified-delivery-solid-20", size: 18).padding(.trailing, 6)
            }
            if let ts = contact.statusTimestamp {
                AxoBaseItem.Text(long(ts), type: .bodyMedium, wrap: .nowrap)
            }
        }
    }
}

/// An images/icons mask drawn in the inherited text colour (`color-svg(…, currentColor)`).
struct IconInheritingColor: View {
    let name: String
    let size: CGFloat
    @Environment(\.cssTextColor) var color
    var body: some View { SignalIcon(name, size: size, color: color, mask: true) }
}
