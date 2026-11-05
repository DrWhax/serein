// Port of ts/components/conversation/poll-message/PollMessageContents.dom.tsx: a poll in a
// bubble — question, "Poll · Select one / multiple" (or "Final results"), each option with a
// round checkbox, its vote count and a bar, and "View votes" (or "No votes").

import SignalI18n
import SwiftUI

/// `PollWithResolvedVotersType` (the parts the bubble renders).
public struct MessagePoll: Sendable, Hashable {
    public enum PendingVote: String, Sendable { case vote = "PENDING_VOTE", unvote = "PENDING_UNVOTE" }
    public var question: String
    public var options: [String]
    public var allowMultiple = false
    public var terminated = false
    public var totalNumVotes = 0
    public var uniqueVoters = 0
    /// Each option's voters (whether each is you).
    public var votesByOption: [Int: [Bool]] = [:]
    public var pendingVoteDiff: [Int: PendingVote] = [:]
    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

/// `PollCheckbox`: a 24px circle, 1.5px border; checked fills it with the accent (incoming) or
/// white (outgoing) and shows the check; pending shows a spinner instead of the border.
struct PollCheckbox: View {
    let checked: Bool
    let isIncoming: Bool
    let isPending: Bool
    let onCheckedChange: (Bool) -> Void

    var body: some View {
        let on = checked && !isPending
        let border: AxoColor = on ? (isIncoming ? .fillAccent : .labelPrimaryOncolor) : (isIncoming ? .labelPlaceholder : .labelPrimaryOncolor)
        let check: AxoColor = on ? (isIncoming ? .labelPrimaryOncolor : .fillAccent) : (isIncoming ? .labelPlaceholder : .labelPrimaryOncolor)
        ZStack {
            if isPending {
                SpinnerV2(value: nil, variant: .custom(bg: nil, fg: border), marginRatio: 1, size: 24, strokeWidth: 1.5)
            }
            SwiftUI.Button { onCheckedChange(!checked) } label: {
                ZStack {
                    if on { Circle().fill(isIncoming ? AxoColor.fillAccent : AxoColor.labelPrimaryOncolor) }
                    if !isPending { Circle().strokeBorder(border, lineWidth: 1.5) }
                    AxoSymbol.Icon("check", size: 16, label: nil).cssTextColor(check).opacity(checked ? 1 : 0)
                }
                .frame(width: 24, height: 24)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
        }
    }
}

public struct PollMessageContents: View {
    let poll: MessagePoll
    let direction: MessageDirection
    let canSendPollVote: Bool
    let sendPollVote: (([Int]) -> Void)?
    let showVotes: (() -> Void)?
    /// mt-1, less what collapses into the margin above it (the author's 3px).
    let topMargin: CGFloat
    @Environment(\.i18n) var i18n

    public init(poll: MessagePoll, direction: MessageDirection, canSendPollVote: Bool, sendPollVote: (([Int]) -> Void)? = nil,
                showVotes: (() -> Void)? = nil, topMargin: CGFloat = 4) {
        self.topMargin = topMargin
        self.poll = poll
        self.direction = direction
        self.canSendPollVote = canSendPollVote
        self.sendPollVote = sendPollVote
        self.showVotes = showVotes
    }

    var isIncoming: Bool { direction == .incoming }
    var primary: AxoColor { isIncoming ? .labelPrimary : .labelPrimaryOncolor }
    var secondary: AxoColor { isIncoming ? .labelSecondary : .labelSecondaryOncolor }

    /// `handlePollOptionClicked`: your votes with the pending diff applied, then the change.
    func toggle(_ index: Int, _ nextChecked: Bool) {
        var selected = Set(poll.votesByOption.filter { $0.value.contains(true) }.map(\.key))
        for (i, diff) in poll.pendingVoteDiff {
            if diff == .vote { selected.insert(i) } else { selected.remove(i) }
        }
        if nextChecked {
            if !poll.allowMultiple { selected.removeAll() }
            selected.insert(index)
        } else {
            selected.remove(index)
        }
        sendPollVote?(selected.sorted())
    }

    public var body: some View {
        let status = poll.terminated ? i18n("icu:PollMessage--FinalResults")
            : i18n(poll.allowMultiple ? "icu:PollMessage--SelectMultiple" : "icu:PollMessage--SelectOne")
        let large = CSSTextStyle(AxoType.bodyLarge).breakingWords()
        VStack(alignment: .leading, spacing: 0) {
            CSSText(runs: [Emojify.run(poll.question)], style: CSSTextStyle(AxoType.bodyLarge.weight(600)).breakingWords(), color: primary)
                .padding(.bottom, 4)
            CSSText(status, style: CSSTextStyle(AxoType.bodyMedium.weight(500)), color: secondary).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(poll.options.indices, id: \.self) { index in
                    option(index, style: large)
                }
            }
            Group {
                if poll.totalNumVotes > 0 {
                    AxoButton.Root(i18n("icu:PollMessage__ViewVotesButton"), variant: .elevatedSecondary, size: .md) { showVotes?() }
                        .environment(\.colorScheme, .light)      // scheme-light
                } else {
                    CSSText(i18n("icu:PollVotesModal__noVotes"), style: CSSTextStyle(AxoType.bodyMedium), color: primary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.top, 16)
        }
        .frame(width: 275, alignment: .leading)
        .padding(.top, topMargin)
    }

    func option(_ index: Int, style: CSSTextStyle) -> some View {
        let voters = poll.votesByOption[index] ?? []
        let percentage = poll.uniqueVoters > 0 ? Double(voters.count) / Double(poll.uniqueVoters) : 0
        let weVoted = voters.contains(true)
        // The pending state shows after 500ms; the captures are taken after it.
        let pending = poll.pendingVoteDiff[index]
        let showCheck = pending.map { $0 == .vote } ?? weVoted
        return HStack(alignment: .top, spacing: 12) {
            if canSendPollVote && !poll.terminated {
                PollCheckbox(checked: showCheck, isIncoming: isIncoming, isPending: pending != nil) { toggle(index, $0) }
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 12) {
                    CSSText(runs: [Emojify.run(poll.options[index])], style: style, color: primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        if poll.terminated && weVoted {
                            AxoSymbol.Icon("check", size: 12, label: i18n("icu:PollMessage--YouVoted"))
                                .cssTextColor(isIncoming ? .labelPrimaryOncolor : .surfaceMessageOutgoing)
                                .frame(width: 16, height: 16)
                                .background(isIncoming ? AxoColor.fillAccent : AxoColor.labelPrimaryOncolor, in: Circle())
                        }
                        CSSText("\(voters.count)", style: CSSTextStyle(AxoType.bodyMedium), wrap: .nowrap, color: secondary)
                    }
                    .opacity(poll.totalNumVotes > 0 ? 1 : 0)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(isIncoming ? AxoColor.fillPrimary : AxoColor.fillOnmessageOutgoingSecondary)
                        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 4, bottomLeading: 4))
                            .fill(isIncoming ? AxoColor.fillAccent : AxoColor.labelPrimaryOncolor)
                            .frame(width: geo.size.width * percentage)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
            }
        }
    }
}
