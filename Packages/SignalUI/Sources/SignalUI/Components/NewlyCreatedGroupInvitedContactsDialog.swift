// Port of ts/components/NewlyCreatedGroupInvitedContactsDialog.dom.tsx: after creating a
// group, the members who could only be invited (who they are, what that means, learn more).

import AppKit
import SignalI18n
import SwiftUI

public struct NewlyCreatedGroupInvitedContactsDialog: View {
    public struct Contact: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var color: String
        public var avatar: RGBAImage?
        public var isMe = false
        public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, isMe: Bool = false) {
            self.id = id
            self.title = title
            self.color = color
            self.avatar = avatar
            self.isMe = isMe
        }
    }

    let contacts: [Contact]
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    static let learnMoreURL = URL(string: "https://support.signal.org/hc/articles/360007319331-Group-chats")!

    public init(contacts: [Contact], onClose: @escaping () -> Void = {}) {
        self.contacts = contacts
        self.onClose = onClose
    }

    var userParagraph: [CSSTextRun] {
        if contacts.count == 1, let contact = contacts.first {
            return CSSTextRun.runs(i18n.richText("icu:NewlyCreatedGroupInvitedContactsDialog--body--user-paragraph--one", ["name": .element("name")]),
                                   elements: ["name": Emojify.run(contact.title)])
        }
        return [CSSTextRun(i18n("icu:NewlyCreatedGroupInvitedContactsDialog--body--user-paragraph--many"))]
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            // OK has autoFocus, so Close does not take the initial focus.
            AxoDialog.Header(focusesClose: false) {
                AxoDialog.Title(i18n("icu:NewlyCreatedGroupInvitedContactsDialog--title", ["count": .number(Double(contacts.count))]))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(padding: .md) {
                VStack(alignment: .leading, spacing: 0) {
                    // <p class="mb-2.5 px-2"> × 2
                    CSSText(runs: userParagraph, style: CSSTextStyle(AxoType.bodyMedium)).padding(.horizontal, 8).padding(.bottom, 10)
                    CSSText(i18n("icu:NewlyCreatedGroupInvitedContactsDialog--body--info-paragraph"), type: .bodyMedium)
                        .padding(.horizontal, 8).padding(.bottom, 10)
                    if contacts.count > 1 {
                        AxoContactList.Root {
                            ForEach(contacts) { contact in
                                AxoContactList.Item(title: contact.title) {
                                    Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 32, conversationType: .direct, color: contact.color,
                                           image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: contact.avatar != nil,
                                           noteToSelf: contact.isMe)
                                } description: {
                                    EmptyView()
                                } accessory: {
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:NewlyCreatedGroupInvitedContactsDialog--body--learn-more"), variant: .subtleSecondary, arrow: .externalLink) {
                        NSWorkspace.shared.open(Self.learnMoreURL)
                    }
                    AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, autoFocus: true, action: onClose)
                }
            }
        }
    }
}
