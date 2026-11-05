// CollapseSetViewer (ts/components/conversation/CollapseSet.dom.tsx): consecutive group
// updates, timer changes or call events folded behind one subtle-secondary button ("N group
// updates · N days", with an expand / collapse arrow; none when selected). Messages that
// were unseen when first shown stay outside the fold (if fewer than two are seen, there is
// no button). Expanding reveals the folded items; right-click offers Select and Delete.
//
// Subset: upstream's height / opacity transition on expand is a plain transition here.

import SignalI18n
import SwiftUI

/// `CollapsedMessage` (ts/util/CollapseSet.std.ts)
public struct CollapsedMessage: Sendable, Hashable, Identifiable {
    public var id: String
    public var isUnseen: Bool
    public var extraItems: Int
    public var atDateBoundary: Bool
    public init(id: String, isUnseen: Bool = false, extraItems: Int = 0, atDateBoundary: Bool = false) {
        self.id = id
        self.isUnseen = isUnseen
        self.extraItems = extraItems
        self.atDateBoundary = atDateBoundary
    }
}

public struct CollapseSetViewer<Item: View>: View {
    public enum Kind: Sendable, Hashable {
        case groupUpdates
        /// `endingState` in seconds (nil / 0: disabled).
        case timerChanges(endingState: Int?)
        case callEvents
    }

    let kind: Kind
    let messages: [CollapsedMessage]
    let isGroup: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let targetedMessageId: String?
    let onDelete: ([String]) -> Void
    let onSelect: ([String]) -> Void
    let renderItem: (CollapsedMessage) -> Item
    @State private var isExpanded = false
    /// The messages as first seen (their original unseen state).
    @State private var firstSeen: [String: CollapsedMessage] = [:]
    @Environment(\.i18n) var i18n

    public init(kind: Kind, messages: [CollapsedMessage], isGroup: Bool, isSelectMode: Bool = false, isSelected: Bool = false,
                targetedMessageId: String? = nil, onDelete: @escaping ([String]) -> Void = { _ in }, onSelect: @escaping ([String]) -> Void = { _ in },
                @ViewBuilder renderItem: @escaping (CollapsedMessage) -> Item) {
        self.kind = kind
        self.messages = messages
        self.isGroup = isGroup
        self.isSelectMode = isSelectMode
        self.isSelected = isSelected
        self.targetedMessageId = targetedMessageId
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.renderItem = renderItem
        // A targeted message inside the set expands it.
        _isExpanded = State(initialValue: targetedMessageId.map { id in messages.contains { $0.id == id } } ?? false)
    }

    struct Split {
        var oldestUnseen: Int?
        var count = 0
        var dayCount = 1
        var showButton: Bool { oldestUnseen.map { $0 > 1 } ?? true }
    }

    var split: Split {
        var s = Split()
        for (i, m) in messages.enumerated() {
            if (firstSeen[m.id] ?? m).isUnseen {
                s.oldestUnseen = i
                break
            }
            s.count += 1 + m.extraItems
            s.dayCount += m.atDateBoundary ? 1 : 0
        }
        return s
    }

    var label: String {
        let s = split
        let text: String
        switch kind {
        case .groupUpdates:
            text = i18n(isGroup ? "icu:collapsedGroupUpdates" : "icu:collapsedChatUpdates", ["count": .number(Double(s.count))])
        case .timerChanges(let endingState):
            if let e = endingState, e != 0 {
                text = i18n("icu:collapsedTimerChanges", ["count": .number(Double(s.count)), "endingState": .string(ExpirationTimer.format(i18n, e))])
            } else {
                text = i18n("icu:collapsedTimerChanges--disabled", ["count": .number(Double(s.count))])
            }
        case .callEvents:
            text = i18n("icu:collapsedCallEvents", ["count": .number(Double(s.count))])
        }
        guard s.dayCount > 1 else { return text }
        return i18n("icu:multidayCollapse__container",
                    ["containerDescription": .string(text),
                     "dayCountSummary": .string(i18n("icu:multidayCollapse__dayCountSummary", ["dayCount": .number(Double(s.dayCount))]))])
    }

    var symbol: AxoSymbol.Name {
        switch kind {
        case .groupUpdates: isGroup ? "group" : "message-thread"
        case .timerChanges: "timer"
        case .callEvents: "phone"
        }
    }

    public var body: some View {
        let s = split
        let cut = s.showButton ? (s.oldestUnseen ?? messages.count) : 0
        let folded = Array(messages.prefix(cut)), passThrough = Array(messages.dropFirst(cut))
        VStack(spacing: 0) {
            if s.showButton {
                AxoButton.Root(label, variant: .subtleSecondary, size: .md, symbol: symbol,
                               arrow: isSelected ? nil : (isExpanded ? .collapse : .expand)) {
                    if !isSelected { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } }
                }
                .accessibilityValue(isSelected ? "" : (isExpanded ? "expanded" : "collapsed"))
                .contextMenu {
                    if !isSelectMode {
                        SwiftUI.Button(i18n("icu:MessageContextMenu__select")) { onSelect(folded.map(\.id)) }
                        SwiftUI.Button(i18n("icu:MessageContextMenu__deleteMessage")) { onDelete(folded.map(\.id)) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)          // my-2.5
                if isSelected || isExpanded {
                    ForEach(folded) { renderItem($0) }
                        .transition(.opacity)
                }
            }
            ForEach(passThrough) { renderItem($0) }
        }
        .onAppear { record() }
        .onChange(of: messages) { record() }
        .onChange(of: targetedMessageId) { _, id in
            if let id, messages.contains(where: { $0.id == id }) { isExpanded = true }
        }
    }

    func record() {
        for m in messages where firstSeen[m.id] == nil { firstSeen[m.id] = m }
    }
}
