// Port of ts/components/StoryDetailsModal.dom.tsx (+ stylesheets/components/
// StoryDetailsModal.scss): the dark "story details" modal in the bottom-right corner. The
// title is a dropdown trigger ("Sent <time>", "File size <size>", "Disappears in <countdown>")
// with Copy timestamp (and Download attachment for internal users); the body lists the
// recipients grouped by send status (Failed, Viewed by, Read by, Delivered to, Sent to,
// Pending), each sorted by title, or, for someone else's story, the sender under "Sent".
//
// Avatar badges are not drawn (donor badges are out of scope).

import AppKit
import SignalI18n
import SwiftUI

/// A recipient's send state (`StorySendStateType`).
public struct StoryDetailsRecipient: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var status: SendStatus
    public var updatedAt: Date?

    public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, status: SendStatus, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct StoryDetailsModal: View {
    let sender: StoryDetailsRecipient
    let sendState: [StoryDetailsRecipient]?
    let timestamp: Date
    let attachmentSize: Int?
    let expirationTimestamp: Date?
    let isInternalUser: Bool
    let onClose: () -> Void
    let onSaveAttachment: () -> Void
    @State private var menuOpen = false
    private var focus = AxoFocusState()
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    /// `sender.status` is unused; `sendState` nil means someone else's story.
    public init(sender: StoryDetailsRecipient, sendState: [StoryDetailsRecipient]?, timestamp: Date, attachmentSize: Int? = nil,
                expirationTimestamp: Date? = nil, isInternalUser: Bool = false, onClose: @escaping () -> Void = {},
                onSaveAttachment: @escaping () -> Void = {}) {
        self.sender = sender
        self.sendState = sendState
        self.timestamp = timestamp
        self.attachmentSize = attachmentSize
        self.expirationTimestamp = expirationTimestamp
        self.isInternalUser = isInternalUser
        self.onClose = onClose
        self.onSaveAttachment = onSaveAttachment
    }

    var now: Date { fixedNow ?? .now }
    func long(_ date: Date) -> String { FormatTimestamp.dateTimeLong(date, now: now, i18n: i18n, timeZone: timeZone) }

    static let groupOrder: [SendStatus] = [.failed, .viewed, .read, .delivered, .sent, .pending]

    func label(_ status: SendStatus) -> String {
        switch status {
        case .failed: i18n("icu:MessageDetailsHeader--Failed")
        case .viewed: i18n("icu:MessageDetailsHeader--Viewed")
        case .read: i18n("icu:MessageDetailsHeader--Read")
        case .delivered: i18n("icu:MessageDetailsHeader--Delivered")
        case .sent: i18n("icu:MessageDetailsHeader--Sent")
        case .pending: i18n("icu:MessageDetailsHeader--Pending")
        }
    }

    public var body: some View {
        ModalHost(onClose: onClose, alignment: .bottomTrailing) {
            ModalPage(modalName: "StoryDetailsModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")), hasXButton: true,
                      onClose: onClose) {
                content
            }
            .titleView(debugger)
            .contentTakesFocus()
            .frame(minWidth: 320)
            .environment(\.colorScheme, .dark)
        }
    }

    /// `__contact-container`: a gray-75 top border over the groups.
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sendState {
                // The sender is in the send state too, but not "sent to".
                let recipients = sendState.filter { $0.id != sender.id }
                ForEach(Self.groupOrder, id: \.self) { status in
                    let group = recipients.filter { $0.status == status }
                        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }    // contactSortCollator
                    if !group.isEmpty {
                        contactGroup(label(status), group.map { ($0, $0.updatedAt) })
                    }
                }
            } else {
                contactGroup(i18n("icu:sent"), [(sender, timestamp)])
            }
        }
        .padding(.top, 1)
        .overlay(alignment: .top) { Rectangle().fill(Color(rgba: LegacyColor.gray75)).frame(height: 1) }
    }

    func contactGroup(_ header: String, _ contacts: [(StoryDetailsRecipient, Date?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // __contact-group__header: font-body-1-bold, padding-block 10px (first child: no top margin).
            CSSText(header, style: LegacyType.body1(weight: 600), wrap: .nowrap)
                .padding(.vertical, 10)
                .padding(.bottom, -8)
            ForEach(contacts, id: \.0.id) { contact, time in
                // __contact: padding-block 8px, 8px apart.
                HStack(alignment: .center, spacing: 0) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 32, conversationType: .direct, color: contact.color,
                           image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
                    ContactName(title: contact.title, style: LegacyType.body1())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                    if let time {
                        CSSText(long(time), style: LegacyType.body1(), wrap: .nowrap)
                            .fixedSize()
                            .padding(.leading, 6)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// `StoryDetailsModal__debugger`: the dropdown trigger in the title.
    var debugger: some View {
        let gray25 = AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray25)
        let bold = LegacyType.body1(weight: 600)
        let regular = AxoFonts.interName(weight: 400)
        func line(_ key: String, _ name: String, _ value: String) -> some View {
            CSSText(runs: CSSTextRun.runs(i18n.richText(key, [name: .element(name)]), elements: [name: CSSTextRun(value, fontName: regular)]),
                    style: bold, wrap: .nowrap, color: gray25)
        }
        let remaining = expirationTimestamp.map { Int($0.timeIntervalSince(now)) }
        return AxoDropdownMenu.Root(isOpen: $menuOpen) {
            Button { menuOpen.toggle() } label: {
                VStack(alignment: .leading, spacing: 0) {
                    line("icu:StoryDetailsModal__sent-time", "time", long(timestamp))
                    if let attachmentSize { line("icu:StoryDetailsModal__file-size", "size", formatFileSize(attachmentSize)) }
                    if let remaining, remaining > 0 {
                        line("icu:StoryDetailsModal__disappears-in", "countdown", ExpirationTimer.format(i18n, remaining, largest: 2))
                    }
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(UndimmedButtonStyle())
            .axoFocusRing(focus.visible(autoFocus: true), in: Rectangle())
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused(focus.$focused)
            .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
        } items: {
            AxoDropdownMenu.Item(i18n("icu:StoryDetailsModal__copy-timestamp"), symbol: "copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(String(Int64(timestamp.timeIntervalSince1970 * 1000)), forType: .string)
            }
            if isInternalUser && attachmentSize != nil {
                AxoDropdownMenu.Item(i18n("icu:StoryDetailsModal__download-attachment"), symbol: "download", action: onSaveAttachment)
            }
        }
    }
}
