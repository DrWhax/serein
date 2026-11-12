// Port of ts/components/conversation/poll-message/PollVotesModal.dom.tsx: who voted for what —
// the question, then each option with its vote count (a star on the winning ones) and its
// voters (36px avatar and name), "No votes" where there are none, and, for the poll's author
// while it runs, "End poll".

import SignalI18n
import SwiftUI

/// `PollVoteWithUserType.from`: one voter.
public struct PollVoter: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public init(id: String, title: String, color: String, avatar: RGBAImage? = nil) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
    }
}

public struct PollVotesModal: View {
    let question: String
    let options: [String]
    let votersByOption: [Int: [PollVoter]]
    let totalNumVotes: Int
    let terminated: Bool
    let canEndPoll: Bool
    let endPoll: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(question: String, options: [String], votersByOption: [Int: [PollVoter]], totalNumVotes: Int, terminated: Bool, canEndPoll: Bool = false,
                endPoll: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.question = question
        self.options = options
        self.votersByOption = votersByOption
        self.totalNumVotes = totalNumVotes
        self.terminated = terminated
        self.canEndPoll = canEndPoll
        self.endPoll = endPoll
        self.onClose = onClose
    }

    var maxVoteCount: Int { votersByOption.values.map(\.count).max() ?? 0 }

    public var body: some View {
        AxoDialog.Content(size: .md, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:PollVotesModal__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 0) {
                    // `mb-3 type-title-small text-primary`
                    CSSText(i18n("icu:PollVotesModal__questionLabel"), style: CSSTextStyle(AxoType.titleSmall), color: .labelPrimary).padding(.bottom, 12)
                    // `mb-3 px-3 py-1 rounded-md bg-primary text-primary type-body-large`
                    CSSText(runs: [Emojify.run(question)], style: CSSTextStyle(AxoType.bodyLarge).breakingWords(), color: .labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AxoColor.fillPrimary))
                        .padding(.bottom, 12)
                    ForEach(options.indices, id: \.self) { index in
                        option(index)
                        if index != options.count - 1 {
                            Rectangle().fill(AxoColor.borderSecondary).frame(height: 0.5).padding(.bottom, 10)
                        }
                    }
                    if totalNumVotes == 0 {
                        CSSText(i18n("icu:PollVotesModal__noVotes"), style: CSSTextStyle(AxoType.bodyLarge), color: .labelSecondary)
                    }
                    if !terminated && canEndPoll {
                        Rectangle().fill(AxoColor.borderPrimary).frame(height: 0.5)
                        AxoButton.Root(i18n("icu:Poll__end-poll"), variant: .strongSecondary, size: .lg) {
                            endPoll()
                            onClose()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    func option(_ index: Int) -> some View {
        let voters = votersByOption[index] ?? []
        let isWinning = !voters.isEmpty && voters.count == maxVoteCount
        return VStack(alignment: .leading, spacing: 0) {
            // Option header: `mb-3 flex items-baseline gap-3`
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CSSText(runs: [Emojify.run(options[index])], style: CSSTextStyle(AxoType.titleSmall).breakingWords(), color: .labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    if isWinning {
                        AxoSymbol.InlineGlyph("star-fill", size: 14, weight: 400)
                            .accessibilityLabel(i18n("icu:PollVotesModal__winningOption"))
                        CSSText("\u{00A0}", style: CSSTextStyle(AxoType.bodyMedium), wrap: .nowrap)
                    }
                    if !voters.isEmpty {
                        CSSText(i18n("icu:PollVotesModal__voteCount", ["count": .number(Double(voters.count))]), style: CSSTextStyle(AxoType.bodyMedium),
                                wrap: .nowrap)
                    }
                }
                .cssTextColor(.labelPrimary)
                .fixedSize()
            }
            .padding(.bottom, 12)
            if voters.isEmpty {
                CSSText(i18n("icu:PollVotesModal__noVotes"), style: CSSTextStyle(AxoType.bodyMedium), color: .labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(voters) { v in
                        HStack(spacing: 12) {
                            Avatar(strings: AvatarStrings(i18n: i18n), title: v.title, size: 36, conversationType: .direct, color: v.color,
                                   image: v.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: v.avatar != nil)
                            ContactName(title: v.title, style: CSSTextStyle(AxoType.bodyLarge))
                                .cssTextColor(.labelPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 10)
    }
}
