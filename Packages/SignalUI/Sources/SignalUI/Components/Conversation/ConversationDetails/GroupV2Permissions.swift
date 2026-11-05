// Port of ts/components/conversation/conversation-details/GroupV2Permissions.dom.tsx: who can
// add members, edit group info, send messages (admins, once announcements-only is available)
// and set member labels: an AxoList of AxoSelectItems ("All members" / "Only admins").
// Restricting labels to admins while non-admins have labels asks first (they will be cleared).

import SignalI18n
import SwiftUI

/// `AccessControlEnum` (the values the selects use).
public enum AccessControl: Int, Sendable { case any = 1, member = 2, administrator = 3 }

public struct GroupV2Permissions: View {
    public struct Callbacks {
        public var setAccessControlAttributesSetting: (AccessControl) -> Void = { _ in }
        public var setAccessControlMembersSetting: (AccessControl) -> Void = { _ in }
        public var setAccessControlMemberLabelSetting: (AccessControl) -> Void = { _ in }
        public var setAnnouncementsOnly: (Bool) -> Void = { _ in }
        public init() {}
    }

    let accessControlMembers: AccessControl?
    let accessControlAttributes: AccessControl?
    let accessControlMemberLabel: AccessControl?
    let announcementsOnly: Bool
    let announcementsOnlyReady: Bool
    let areWeAdmin: Bool
    let nonAdminsHaveLabels: Bool
    let callbacks: Callbacks
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(accessControlMembers: AccessControl? = nil, accessControlAttributes: AccessControl? = nil, accessControlMemberLabel: AccessControl? = nil,
                announcementsOnly: Bool = false, announcementsOnlyReady: Bool = false, areWeAdmin: Bool = false, nonAdminsHaveLabels: Bool = false,
                callbacks: Callbacks = Callbacks()) {
        self.accessControlMembers = accessControlMembers
        self.accessControlAttributes = accessControlAttributes
        self.accessControlMemberLabel = accessControlMemberLabel
        self.announcementsOnly = announcementsOnly
        self.announcementsOnlyReady = announcementsOnlyReady
        self.areWeAdmin = areWeAdmin
        self.nonAdminsHaveLabels = nonAdminsHaveLabels
        self.callbacks = callbacks
    }

    var options: [AxoSelectItem.Option] {
        [AxoSelectItem.Option(value: String(AccessControl.member.rawValue), label: i18n("icu:GroupV2--all-members")),
         AxoSelectItem.Option(value: String(AccessControl.administrator.rawValue), label: i18n("icu:GroupV2--only-admins"))]
    }

    func binding(_ value: AccessControl?, _ set: @escaping (AccessControl) -> Void) -> Binding<String?> {
        Binding(get: { String((value ?? .member).rawValue) },
                set: { v in if let v, let n = Int(v), let a = AccessControl(rawValue: n) { set(a) } })
    }

    func updateMemberLabel(_ value: AccessControl) {
        guard value == .administrator, nonAdminsHaveLabels, let modals else {
            callbacks.setAccessControlMemberLabelSetting(value)
            return
        }
        let id = "group-v2-permissions-clear-labels"
        modals.present(id: id) {
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    AxoAlertDialog.Title(i18n("icu:ConversationDetails--label-clear-warning--title"))
                    AxoAlertDialog.Description(i18n("icu:ConversationDetails--label-clear-warning--description"))
                }
                AxoAlertDialog.Footer {
                    AxoAlertDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary) { modals.dismiss(id: id) }
                    AxoAlertDialog.Action(i18n("icu:ConversationDetails--label-clear-warning--continue"), variant: .strongPrimary) {
                        callbacks.setAccessControlMemberLabelSetting(.administrator)
                        modals.dismiss(id: id)
                    }
                }
            }
        }
    }

    public var body: some View {
        let showAnnouncementsOnly = areWeAdmin && (announcementsOnly || announcementsOnlyReady)
        AxoContainer.Root {
            AxoList.Root {
                AxoList.Body {
                    AxoItem.Group {
                        AxoSelectItem.Root(label: i18n("icu:ConversationDetails--add-members-label"), description: i18n("icu:ConversationDetails--add-members-info"),
                                           placeholder: "", value: binding(accessControlMembers, callbacks.setAccessControlMembersSetting), options: options)
                        AxoSelectItem.Root(label: i18n("icu:ConversationDetails--group-info-label"), description: i18n("icu:ConversationDetails--group-info-info-v2"),
                                           placeholder: "", value: binding(accessControlAttributes, callbacks.setAccessControlAttributesSetting), options: options)
                        if showAnnouncementsOnly {
                            AxoSelectItem.Root(label: i18n("icu:ConversationDetails--announcement-label"), description: i18n("icu:ConversationDetails--announcement-info"),
                                               placeholder: "", value: binding(announcementsOnly ? .administrator : .member, { callbacks.setAnnouncementsOnly($0 == .administrator) }),
                                               options: options)
                        }
                        AxoSelectItem.Root(label: i18n("icu:ConversationDetails--member-label--label"), description: i18n("icu:ConversationDetails--member-label--info"),
                                           placeholder: "", value: binding(accessControlMemberLabel, updateMemberLabel), options: options)
                    }
                }
            }
        }
    }
}
