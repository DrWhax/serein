// Port of ts/components/conversation/GroupNotification.dom.tsx: a legacy (pre-groups-v2)
// group update. "{name} updated the group." beside the group icon, then one paragraph per
// change (new name, avatar, joined, left); a lone "left" change is shown without the
// "updated" line. Joined / left contacts are bold (`.module-group-notification__contact`).

import SignalI18n
import SwiftUI

public struct GroupNotification: View {
    public enum Change: Sendable, Hashable {
        public struct Contact: Sendable, Hashable {
            public var id: String
            public var title: String
            public var isMe: Bool
            public init(id: String, title: String, isMe: Bool = false) {
                self.id = id
                self.title = title
                self.isMe = isMe
            }
        }
        case add([Contact])
        case remove([Contact])
        case name(String?)
        case avatar
        case general
    }

    let fromTitle: String
    let fromIsMe: Bool
    let changes: [Change]
    @Environment(\.i18n) var i18n

    public init(fromTitle: String, fromIsMe: Bool = false, changes: [Change]) {
        self.fromTitle = fromTitle
        self.fromIsMe = fromIsMe
        self.changes = changes
    }

    static func contact(_ title: String, bold: Bool) -> CSSTextRun {
        var run = Emojify.run(title)
        if bold { run.fontName = AxoFonts.interName(weight: 700) }
        return run
    }

    func rich(_ key: String, _ elements: [String: [CSSTextRun]]) -> [CSSTextRun] {
        var args: [String: I18nArgument] = [:]
        for name in elements.keys { args[name] = .element(name) }
        return CSSTextRun.runs(i18n.richText(key, args), elementRuns: elements)
    }

    /// `GroupNotificationChange`: nil renders nothing (`general`).
    func paragraph(_ change: Change) -> [[CSSTextRun]] {
        switch change {
        case .name(let name):
            return [rich("icu:titleIsNow", ["name": [CSSTextRun(name ?? "")]])]
        case .avatar:
            return [[CSSTextRun(i18n("icu:updatedGroupAvatar"))]]
        case .add(let contacts):
            let others = contacts.filter { !$0.isMe }
            var out: [CSSTextRun] = []
            if others.count == 1 {
                out = rich("icu:joinedTheGroup", ["name": [Self.contact(others[0].title, bold: true)]])
            } else if !others.isEmpty {
                out = rich("icu:multipleJoinedTheGroup", ["names": withCommas(others)])
            }
            // "You joined the group." is a <div> inside the same <p>: the next line, no margin.
            if others.count != contacts.count {
                if !out.isEmpty { out.append(CSSTextRun("\n")) }
                out.append(CSSTextRun(i18n("icu:youJoinedTheGroup")))
            }
            return [out]
        case .remove(let contacts):
            if fromIsMe { return [[CSSTextRun(i18n("icu:youLeftTheGroup"))]] }
            let others = contacts.filter { !$0.isMe }
            // Upstream passes the first person to the plural string and the list to the
            // singular one; kept as is.
            return contacts.count > 1
                ? [rich("icu:multipleLeftTheGroup", ["name": others.first.map { [Self.contact($0.title, bold: true)] } ?? []])]
                : [rich("icu:leftTheGroup", ["name": withCommas(others)])]
        case .general:
            return [[]]          // an empty <p>
        }
    }

    func withCommas(_ contacts: [Change.Contact]) -> [CSSTextRun] {
        var runs: [CSSTextRun] = []
        for (i, c) in contacts.enumerated() {
            if i > 0 { runs.append(CSSTextRun(", ")) }
            runs.append(Self.contact(c.title, bold: true))
        }
        return runs
    }

    public var body: some View {
        let isLeftOnly: Bool = if changes.count == 1, case .remove = changes[0] { true } else { false }
        let first: [CSSTextRun]
        var rest: [[CSSTextRun]] = []
        if isLeftOnly {
            let lines = paragraph(changes[0])
            first = lines.first ?? []
            rest = Array(lines.dropFirst())
        } else {
            first = fromIsMe ? [CSSTextRun(i18n("icu:youUpdatedTheGroup"))]
                : rich("icu:updatedTheGroup", ["name": [Self.contact(fromTitle, bold: false)]])
            rest = changes.flatMap { paragraph($0) }
        }
        return SystemMessage(.icon("v3/group/group-compact"), contents: first, paragraphs: rest).contentsIsParagraph()
    }
}
