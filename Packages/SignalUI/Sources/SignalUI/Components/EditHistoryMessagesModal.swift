// Port of ts/components/EditHistoryMessagesModal.dom.tsx: the current version of an edited
// message (marked Edited) under its date, a divider, then "Edit history" with the earlier
// versions (date headers between days); each message offers Copy timestamp.

import AppKit
import SignalI18n
import SwiftUI

public struct EditHistoryMessagesModal: View {
    /// The current message first, then the earlier versions.
    let editHistoryMessages: [MessageProps]
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone

    public init(editHistoryMessages: [MessageProps], onClose: @escaping () -> Void = {}) {
        self.editHistoryMessages = editHistoryMessages
        self.onClose = onClose
    }

    func message(_ p: MessageProps, edited: Bool) -> some View {
        var p = p
        p.isEdited = edited
        p.showEditHistory = {}                  // showEditHistoryModal: noop
        let ts = p.timestamp
        return Message(props: p)
            .contextMenu {
                SwiftUI.Button(i18n("icu:EditHistoryMessagesModal__Message__ContextMenu__CopyTimestamp")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(Int64(ts.timeIntervalSince1970 * 1000)), forType: .string)
                }
            }
    }

    func sameDay(_ a: Date, _ b: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.isDate(a, inSameDayAs: b)
    }

    public var body: some View {
        let current = editHistoryMessages.first
        let past = Array(editHistoryMessages.dropFirst())
        AxoDialog.Content(size: .md, hasHeader: false, hasFooter: false) {
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    if let current {
                        TimelineDateHeader(timestamp: current.timestamp, noPaddingTop: true)
                        message(current, edited: true)
                    }
                    // __divider: margin-block 24, 1px gray-15 / gray-75
                    Rectangle().fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75)).frame(height: 1).padding(.vertical, 24)
                    CSSText(i18n("icu:EditHistoryMessagesModal__title"), style: LegacyType.body1(weight: 700), color: .labelPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(past.indices, id: \.self) { i in
                        let previous = i == 0 ? current : past[i - 1]
                        if let previous, past[i].timestamp > previous.timestamp, !sameDay(previous.timestamp, past[i].timestamp) {
                            TimelineDateHeader(timestamp: past[i].timestamp)
                        }
                        message(past[i], edited: false)
                    }
                }
                .environment(\.messagePaddingInline, 0)
                // In the (transformed) dialog, fixed-attachment gradients fill each bubble's own box.
                .environment(\.chatColorViewport, nil)
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) {
                AxoDialog.Title(i18n("icu:EditHistoryMessagesModal__title"))
                AxoDialog.Close(action: onClose)
            }
        }
    }
}
