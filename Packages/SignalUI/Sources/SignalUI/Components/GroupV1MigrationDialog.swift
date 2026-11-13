// Port of ts/components/GroupV1MigrationDialog.dom.tsx: what the New Groups migration does,
// then the invited and the dropped members (a sorted contact list, or just their count).

import SignalI18n
import SwiftUI

/// A member shown in the migration dialog.
public struct GroupV1MigrationMember: Identifiable {
    public var id: String
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var isMe: Bool
    public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, isMe: Bool = false) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
        self.isMe = isMe
    }
}

public struct GroupV1MigrationDialog: View {
    let areWeInvited: Bool
    let droppedMembers: [GroupV1MigrationMember]?
    let droppedMemberCount: Int
    let invitedMembers: [GroupV1MigrationMember]?
    let invitedMemberCount: Int
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(areWeInvited: Bool, droppedMembers: [GroupV1MigrationMember]?, droppedMemberCount: Int, invitedMembers: [GroupV1MigrationMember]?,
                invitedMemberCount: Int, onClose: @escaping () -> Void = {}) {
        self.areWeInvited = areWeInvited
        self.droppedMembers = droppedMembers
        self.droppedMemberCount = droppedMemberCount
        self.invitedMembers = invitedMembers
        self.invitedMemberCount = invitedMemberCount
        self.onClose = onClose
    }

    /// `p.mb-2.5.px-2`
    func paragraph(_ text: String) -> some View {
        CSSText(text, type: .bodyMedium).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 10)
    }

    @ViewBuilder func members(invited: Bool, _ members: [GroupV1MigrationMember]?, count: Int) -> some View {
        if count > 0 {
            if let members {
                let sorted = members.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let key = invited ? (sorted.count == 1 ? "icu:GroupV1--Migration--info--invited--one" : "icu:GroupV1--Migration--info--invited--many")
                    : (sorted.count == 1 ? "icu:GroupV1--Migration--info--removed--after--one" : "icu:GroupV1--Migration--info--removed--after--many")
                VStack(spacing: 0) {
                    paragraph(i18n(key))
                    AxoContactList.Root {
                        ForEach(sorted) { m in
                            AxoContactList.Item(title: m.title) {
                                Avatar(strings: AvatarStrings(i18n: i18n), title: m.title, size: 32, conversationType: .direct, color: m.color,
                                       image: m.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: m.avatar != nil, noteToSelf: m.isMe)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            } else {
                paragraph(i18n(invited ? "icu:GroupV1--Migration--info--invited--count" : "icu:GroupV1--Migration--info--removed--after--count",
                               ["count": .number(Double(count))]))
            }
        }
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:GroupV1--Migration--info--title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(padding: .md) {
                VStack(spacing: 0) {
                    paragraph(i18n("icu:GroupV1--Migration--info--summary"))
                    paragraph(i18n("icu:GroupV1--Migration--info--keep-history"))
                    if areWeInvited {
                        paragraph(i18n("icu:GroupV1--Migration--info--invited--you"))
                    } else {
                        members(invited: true, invitedMembers, count: invitedMemberCount)
                        members(invited: false, droppedMembers, count: droppedMemberCount)
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions { AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, autoFocus: true, action: onClose) }
            }
        }
    }
}
