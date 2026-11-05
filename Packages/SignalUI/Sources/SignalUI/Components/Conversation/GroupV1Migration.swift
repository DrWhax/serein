// GroupV1Migration (ts/components/conversation/GroupV1Migration.dom.tsx): the "upgraded to a
// New Group" SystemMessage. Its contents are paragraphs: the first is `inline-block` after
// the group icon (`p:first-child`) with 4px below it, then a block holding either "You
// couldn't be added…" or one paragraph each for invited / removed members (4px apart).
// "Learn More" opens GroupV1MigrationDialog through `onLearnMore`.

import SignalI18n
import SwiftUI

public struct GroupV1Migration: View {
    let areWeInvited: Bool
    let invitedMembers: [String]?
    let invitedMemberCount: Int
    let droppedMembers: [String]?
    let droppedMemberCount: Int
    let onLearnMore: () -> Void
    @Environment(\.i18n) var i18n

    /// - Parameters: invitedMembers / droppedMembers: the members' titles.
    public init(areWeInvited: Bool, invitedMembers: [String]?, invitedMemberCount: Int, droppedMembers: [String]?, droppedMemberCount: Int,
                onLearnMore: @escaping () -> Void = {}) {
        self.areWeInvited = areWeInvited
        self.invitedMembers = invitedMembers
        self.invitedMemberCount = invitedMemberCount
        self.droppedMembers = droppedMembers
        self.droppedMemberCount = droppedMemberCount
        self.onLearnMore = onLearnMore
    }

    /// `renderUsers`
    func users(_ members: [String]?, _ count: Int, invited: Bool) -> [CSSTextRun]? {
        guard count > 0 else { return nil }
        if let members, count == 1, let first = members.first {
            var contact = CSSTextRun(first)
            contact.emojify = true
            return CSSTextRun.runs(i18n.richText(invited ? "icu:GroupV1--Migration--invited--one" : "icu:GroupV1--Migration--removed--one",
                                                 ["contact": .element("contact")]), elements: ["contact": contact])
        }
        return CSSTextRun.runs(i18n.richText(invited ? "icu:GroupV1--Migration--invited--many" : "icu:GroupV1--Migration--removed--many",
                                             ["count": .number(Double(count))]))
    }

    var memberParagraphs: [[CSSTextRun]] {
        if areWeInvited { return [[CSSTextRun(i18n("icu:GroupV1--Migration--invited--you"))]] }
        return [users(invitedMembers, invitedMemberCount, invited: true), users(droppedMembers, droppedMemberCount, invited: false)].compactMap { $0 }
    }

    public var body: some View {
        let style = SystemMessage<EmptyView>.style
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    SignalIcon("v3/group/group-compact", size: 16, color: .labelSecondary)
                    CSSText(i18n("icu:GroupV1--Migration--was-upgraded"), style: style, alignment: .center)
                }
                .padding(.bottom, 4)
                VStack(spacing: 4) {
                    ForEach(memberParagraphs.indices, id: \.self) { i in
                        CSSText(runs: memberParagraphs[i], style: style, alignment: .center)
                    }
                }
            }
            .frame(maxWidth: 400)
            .cssTextColor(.labelSecondary)
            LegacyButton(i18n("icu:GroupV1--Migration--learn-more"), size: .small, variant: .systemMessage, action: onLearnMore)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
