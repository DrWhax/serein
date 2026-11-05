// GroupV2Change (ts/components/conversation/GroupV2Change.dom.tsx + ts/groupChange.std.ts):
// each detail of a group change as a SystemMessage with its icon, worded for who made the
// change (you / a member / unknown) and who it affects. A changed description has "View"
// (the description dialog); a join-request bounce from a non-member offers "Block request"
// to admins (a confirm dialog).

import SignalI18n
import SwiftUI

/// `GroupV2ChangeDetailType` (ts/types/groups.std.ts): `type` and the fields it uses.
public struct GroupV2ChangeDetail: Sendable, Hashable, Codable {
    public var type: String
    public var aci: String?
    public var pni: String?
    public var inviter: String?
    public var serviceId: String?
    public var newTitle: String?
    public var removed: Bool?
    /// AccessControl.AccessRequired (ANY 1, MEMBER 2, ADMINISTRATOR 3) or Member.Role (DEFAULT 1, ADMINISTRATOR 2).
    public var newPrivilege: Int?
    public var privilege: Int?
    public var count: Int?
    public var times: Int?
    public var isApprovalPending: Bool?
    public var description: String?
    public var announcementsOnly: Bool?

    public init(type: String, aci: String? = nil, pni: String? = nil, inviter: String? = nil, serviceId: String? = nil, newTitle: String? = nil,
                removed: Bool? = nil, newPrivilege: Int? = nil, privilege: Int? = nil, count: Int? = nil, times: Int? = nil,
                isApprovalPending: Bool? = nil, description: String? = nil, announcementsOnly: Bool? = nil) {
        self.type = type
        self.aci = aci
        self.pni = pni
        self.inviter = inviter
        self.serviceId = serviceId
        self.newTitle = newTitle
        self.removed = removed
        self.newPrivilege = newPrivilege
        self.privilege = privilege
        self.count = count
        self.times = times
        self.isApprovalPending = isApprovalPending
        self.description = description
        self.announcementsOnly = announcementsOnly
    }
}

/// `GroupV2ChangeType`
public struct GroupV2ChangeModel: Sendable, Hashable, Codable {
    public var from: String?
    public var details: [GroupV2ChangeDetail]
    public init(from: String?, details: [GroupV2ChangeDetail]) {
        self.from = from
        self.details = details
    }
}

/// ts/groupChange.std.ts `renderChange`, producing CSSText runs (contacts via `renderContact`).
public struct GroupChangeRenderer {
    enum AccessRequired { static let any = 1, member = 2, administrator = 3 }
    enum Role { static let `default` = 1, administrator = 2 }

    public enum Arg {
        case contact(String)
        case string(String)
        case number(Int)
    }

    public struct Result {
        public var detail: GroupV2ChangeDetail
        public var isLastText: Bool
        public var text: [CSSTextRun]
    }

    let i18n: Localizer
    let ourAci: String?
    let ourPni: String?
    let renderContact: (String) -> CSSTextRun

    public init(i18n: Localizer, ourAci: String?, ourPni: String?, renderContact: @escaping (String) -> CSSTextRun) {
        self.i18n = i18n
        self.ourAci = ourAci
        self.ourPni = ourPni
        self.renderContact = renderContact
    }

    public func render(_ change: GroupV2ChangeModel) -> [Result] {
        change.details.flatMap { detail -> [Result] in
            let texts = renderDetail(detail, from: change.from)
            return texts.enumerated().map { Result(detail: detail, isLastText: $0.offset == texts.count - 1, text: $0.element) }
        }
    }

    func say(_ key: String, _ args: [String: Arg] = [:]) -> [CSSTextRun] {
        var arguments: [String: I18nArgument] = [:]
        var elements: [String: CSSTextRun] = [:]
        for (name, arg) in args {
            switch arg {
            case .contact(let id):
                arguments[name] = .element(name)
                elements[name] = renderContact(id)
            case .string(let s):
                arguments[name] = .element(name)
                var run = CSSTextRun(s)         // UserText: emojified
                run.emojify = true
                elements[name] = run
            case .number(let n):
                arguments[name] = .number(Double(n))
            }
        }
        return CSSTextRun.runs(i18n.richText(key, arguments), elements: elements)
    }

    func isOurs(_ id: String?) -> Bool {
        guard let id else { return false }
        return (ourAci != nil && id == ourAci) || (ourPni != nil && id == ourPni)
    }

    /// The common "--you" / "--other" (named `nameKey`) / "--unknown" triple.
    func byWho(_ base: String, from: String?, nameKey: String = "memberName", _ extra: [String: Arg] = [:]) -> [CSSTextRun] {
        if isOurs(from) { return say(base + "--you", extra) }
        if let from {
            var args = extra
            args[nameKey] = .contact(from)
            return say(base + "--other", args)
        }
        return say(base + "--unknown", extra)
    }

    func renderDetail(_ d: GroupV2ChangeDetail, from: String?) -> [[CSSTextRun]] {
        let fromYou = isOurs(from)
        let p = "icu:GroupV2--"
        switch d.type {
        case "create":
            return [byWho(p + "create", from: from)]
        case "title":
            if let t = d.newTitle, !t.isEmpty { return [byWho(p + "title--change", from: from, ["newTitle": .string(t)])] }
            return [byWho(p + "title--remove", from: from)]
        case "avatar":
            return [byWho(p + (d.removed == true ? "avatar--remove" : "avatar--change"), from: from)]
        case "access-attributes", "access-members", "access-member-label":
            switch d.newPrivilege {
            case AccessRequired.administrator: return [byWho(p + d.type + "--admins", from: from, nameKey: "adminName")]
            case AccessRequired.member: return [byWho(p + d.type + "--all", from: from, nameKey: "adminName")]
            default: return [[]]
            }
        case "access-invite-link":
            switch d.newPrivilege {
            case AccessRequired.administrator: return [byWho(p + "access-invite-link--enabled", from: from, nameKey: "adminName")]
            case AccessRequired.any: return [byWho(p + "access-invite-link--disabled", from: from, nameKey: "adminName")]
            default: return [[]]
            }
        case "member-add":
            let aci = d.aci ?? ""
            if isOurs(d.aci) { return [byWho(p + "member-add--you", from: from)] }
            if fromYou { return [say(p + "member-add--other--you", ["memberName": .contact(aci)])] }
            if let from { return [say(p + "member-add--other--other", ["adderName": .contact(from), "addeeName": .contact(aci)])] }
            return [say(p + "member-add--other--unknown", ["memberName": .contact(aci)])]
        case "member-add-from-invite":
            let aci = d.aci ?? ""
            let fromPni = d.pni != nil && from == d.pni
            let fromAci = from == d.aci
            if from == nil || (!fromPni && !fromAci) {
                if isOurs(d.aci) {
                    if let from { return [say(p + "member-add--you--other", ["memberName": .contact(from)])] }
                    return [say(p + "member-add--you--unknown")]
                }
                if fromYou { return [say(p + "member-add--invited--you", ["inviteeName": .contact(aci)])] }
                if let from { return [say(p + "member-add--invited--other", ["memberName": .contact(from), "inviteeName": .contact(aci)])] }
                return [say(p + "member-add--invited--unknown", ["inviteeName": .contact(aci)])]
            }
            if isOurs(d.aci) {
                if let inviter = d.inviter { return [say(p + "member-add--from-invite--you", ["inviterName": .contact(inviter)])] }
                return [say(p + "member-add--from-invite--you-no-from")]
            }
            if isOurs(d.inviter) { return [say(p + "member-add--from-invite--from-you", ["inviteeName": .contact(aci)])] }
            if let inviter = d.inviter {
                return [say(p + "member-add--from-invite--other", ["inviteeName": .contact(aci), "inviterName": .contact(inviter)])]
            }
            return [say(p + "member-add--from-invite--other-no-from", ["inviteeName": .contact(aci)])]
        case "member-add-from-link":
            let aci = d.aci ?? ""
            if fromYou && isOurs(d.aci) { return [say(p + "member-add-from-link--you--you")] }
            if let from, aci == from { return [say(p + "member-add-from-link--other", ["memberName": .contact(from)])] }
            return [say(p + "member-add--other--unknown", ["memberName": .contact(aci)])]
        case "member-add-from-admin-approval":
            let aci = d.aci ?? ""
            let k = p + "member-add-from-admin-approval"
            if isOurs(d.aci) {
                if let from { return [say(k + "--you--other", ["adminName": .contact(from)])] }
                return [say(k + "--you--unknown")]
            }
            if fromYou { return [say(k + "--other--you", ["joinerName": .contact(aci)])] }
            if let from { return [say(k + "--other--other", ["adminName": .contact(from), "joinerName": .contact(aci)])] }
            return [say(k + "--other--unknown", ["joinerName": .contact(aci)])]
        case "member-remove":
            let aci = d.aci ?? ""
            let k = p + "member-remove"
            if isOurs(d.aci) {
                if fromYou { return [say(k + "--you--you")] }
                if let from { return [say(k + "--you--other", ["adminName": .contact(from)])] }
                return [say(k + "--you--unknown")]
            }
            if fromYou { return [say(k + "--other--you", ["memberName": .contact(aci)])] }
            if let from, from == aci { return [say(k + "--other--self", ["memberName": .contact(from)])] }
            if let from { return [say(k + "--other--other", ["adminName": .contact(from), "memberName": .contact(aci)])] }
            return [say(k + "--other--unknown", ["memberName": .contact(aci)])]
        case "member-privilege":
            let aci = d.aci ?? ""
            let verb: String
            switch d.newPrivilege {
            case Role.administrator: verb = "promote"
            case Role.default: verb = "demote"
            default: return [[]]
            }
            let k = p + "member-privilege--" + verb
            if isOurs(d.aci) {
                if let from { return [say(k + "--you--other", ["adminName": .contact(from)])] }
                return [say(k + "--you--unknown")]
            }
            if fromYou { return [say(k + "--other--you", ["memberName": .contact(aci)])] }
            if let from { return [say(k + "--other--other", ["adminName": .contact(from), "memberName": .contact(aci)])] }
            return [say(k + "--other--unknown", ["memberName": .contact(aci)])]
        case "pending-add-one":
            let id = d.serviceId ?? ""
            let k = p + "pending-add--one"
            if isOurs(d.serviceId) {
                if let from { return [say(k + "--you--other", ["memberName": .contact(from)])] }
                return [say(k + "--you--unknown")]
            }
            if fromYou { return [say(k + "--other--you", ["inviteeName": .contact(id)])] }
            if let from { return [say(k + "--other--other", ["memberName": .contact(from)])] }
            return [say(k + "--other--unknown")]
        case "pending-add-many":
            return [byWho(p + "pending-add--many", from: from, ["count": .number(d.count ?? 0)])]
        case "pending-remove-one":
            return [pendingRemoveOne(d, from: from)]
        case "pending-remove-many":
            let count = Arg.number(d.count ?? 0)
            if isOurs(d.inviter) {
                return [byWho(p + "pending-remove--revoke-invite-from-you--many", from: from, nameKey: "adminName", ["count": count])]
            }
            if let inviter = d.inviter {
                return [byWho(p + "pending-remove--revoke-invite-from--many", from: from, nameKey: "adminName",
                              ["count": count, "memberName": .contact(inviter)])]
            }
            return [byWho(p + "pending-remove--revoke--many", from: from, ["count": count])]
        case "admin-approval-add-one":
            if isOurs(d.aci) { return [say(p + "admin-approval-add-one--you")] }
            return [say(p + "admin-approval-add-one--other", ["joinerName": .contact(d.aci ?? "")])]
        case "admin-approval-remove-one":
            let aci = d.aci ?? ""
            let k = p + "admin-approval-remove-one"
            if isOurs(d.aci) { return [say(k + (fromYou ? "--you--you" : "--you--unknown"))] }
            if fromYou { return [say(k + "--other--you", ["joinerName": .contact(aci)])] }
            if let from { return [say(k + "--other--other", ["adminName": .contact(from), "joinerName": .contact(aci)])] }
            return [say(k + "--other--unknown", ["joinerName": .contact(aci)])]
        case "admin-approval-bounce":
            let aci = d.aci ?? ""
            let first = say(p + "admin-approval-bounce--pluralized", ["joinerName": .contact(aci), "numberOfRequests": .number(d.times ?? 0)])
            guard d.isApprovalPending == true else { return [first] }
            return [first] + renderDetail(GroupV2ChangeDetail(type: "admin-approval-add-one", aci: aci), from: from)
        case "group-link-add":
            switch d.privilege {
            case AccessRequired.administrator: return [byWho(p + "group-link-add--enabled", from: from, nameKey: "adminName")]
            case AccessRequired.any: return [byWho(p + "group-link-add--disabled", from: from, nameKey: "adminName")]
            default: return [[]]
            }
        case "group-link-reset":
            return [byWho(p + "group-link-reset", from: from, nameKey: "adminName")]
        case "group-link-remove":
            return [byWho(p + "group-link-remove", from: from, nameKey: "adminName")]
        case "description":
            return [byWho(p + (d.removed == true ? "description--remove" : "description--change"), from: from)]
        case "announcements-only":
            return [byWho(p + (d.announcementsOnly == true ? "announcements--admin" : "announcements--member"), from: from)]
        case "terminated":
            return [byWho(p + "terminated", from: from)]
        case "summary":
            return [say(p + "summary")]
        default:
            return [[]]
        }
    }

    func pendingRemoveOne(_ d: GroupV2ChangeDetail, from: String?) -> [CSSTextRun] {
        let p = "icu:GroupV2--pending-remove--"
        let fromYou = isOurs(from)
        guard let serviceId = d.serviceId else { return say(p + "decline--unknown") }
        let sentByInvited = from != nil && from == serviceId
        let sentByInviter = from != nil && d.inviter != nil && from == d.inviter
        if isOurs(d.inviter) {
            if sentByInvited { return say(p + "decline--you", ["inviteeName": .contact(serviceId)]) }
            return byWho(p + "revoke-invite-from-you--one", from: from, nameKey: "adminName", ["inviteeName": .contact(serviceId)])
        }
        if sentByInvited {
            if fromYou { return say(p + "decline--from-you") }
            if let inviter = d.inviter { return say(p + "decline--other", ["memberName": .contact(inviter)]) }
            return say(p + "decline--unknown")
        }
        if let inviter = d.inviter, sentByInviter {
            return say(p + (isOurs(serviceId) ? "revoke-own--to-you" : "revoke-own--unknown"), ["inviterName": .contact(inviter)])
        }
        if let inviter = d.inviter {
            return byWho(p + "revoke-invite-from--one", from: from, nameKey: "adminName", ["memberName": .contact(inviter)])
        }
        return byWho(p + "revoke--one", from: from)
    }
}

public struct GroupV2Change: View {
    public struct Membership: Sendable, Hashable, Codable {
        public var aci: String
        public var isAdmin: Bool
        public init(aci: String, isAdmin: Bool) {
            self.aci = aci
            self.isAdmin = isAdmin
        }
    }

    let change: GroupV2ChangeModel
    let areWeAdmin: Bool
    let groupMemberships: [Membership]?
    let groupBannedMemberships: [String]?
    let groupName: String?
    let ourAci: String?
    let ourPni: String?
    let renderContact: (String) -> CSSTextRun
    let blockGroupLinkRequests: (String) -> Void
    let viewDescription: (String) -> Void
    @Environment(\.i18n) var i18n

    public init(change: GroupV2ChangeModel, areWeAdmin: Bool, groupMemberships: [Membership]? = nil, groupBannedMemberships: [String]? = nil,
                groupName: String? = nil, ourAci: String?, ourPni: String?, renderContact: @escaping (String) -> CSSTextRun,
                blockGroupLinkRequests: @escaping (String) -> Void = { _ in }, viewDescription: @escaping (String) -> Void = { _ in }) {
        self.change = change
        self.areWeAdmin = areWeAdmin
        self.groupMemberships = groupMemberships
        self.groupBannedMemberships = groupBannedMemberships
        self.groupName = groupName
        self.ourAci = ourAci
        self.ourPni = ourPni
        self.renderContact = renderContact
        self.blockGroupLinkRequests = blockGroupLinkRequests
        self.viewDescription = viewDescription
    }

    /// `changeToIconMap` + `getIcon`: (images/icons path, width).
    static func icon(_ detail: GroupV2ChangeDetail, isLastText: Bool, fromId: String?) -> (String, CGFloat) {
        var name: String?
        switch detail.type {
        case "access-attributes", "access-invite-link", "access-member-label", "access-members", "announcements-only", "group-link-add",
             "group-link-remove", "group-link-reset", "member-privilege": name = "group-access"
        case "admin-approval-add-one", "member-add", "member-add-from-invite", "member-add-from-link", "pending-add-many", "pending-add-one": name = "group-add"
        case "admin-approval-bounce", "admin-approval-remove-one", "pending-remove-many", "pending-remove-one": name = "group-decline"
        case "avatar": name = "group-avatar"
        case "description", "title": name = "group-edit"
        case "member-add-from-admin-approval": name = "group-approved"
        case "member-remove": name = "group-remove"
        case "summary": name = "group-summary"
        case "terminated": name = "group-terminate"
        default: name = "group"
        }
        if fromId != nil, fromId == detail.aci {
            if detail.type == "member-remove" { name = "group-leave" }
            if detail.type == "member-add-from-invite" { name = "group-approved" }
        }
        if detail.type == "admin-approval-bounce" && isLastText { name = nil }
        switch name ?? "group" {
        case "group-access": return ("v3/megaphone/megaphone-compact", 16)
        case "group-add": return ("v3/person/person-plus-compact", 16)
        case "group-approved": return ("v3/person/person-check-compact", 16)
        case "group-avatar": return ("v3/photo/photo-square-compact", 16)
        case "group-decline": return ("v3/person/person-x-compact", 16)
        case "group-edit": return ("v3/edit/edit-compact", 16)
        case "group-leave": return ("v3/leave/leave-compact", 16)
        case "group-remove": return ("v3/person/person-minus-compact", 16)
        case "group-summary": return ("v3/info/info-compact", 16)
        case "group-terminate": return ("v3/group/group-x-inline", 24)
        default: return ("v3/group/group-compact", 16)
        }
    }

    public var body: some View {
        let results = GroupChangeRenderer(i18n: i18n, ourAci: ourAci, ourPni: ourPni, renderContact: renderContact).render(change)
        VStack(spacing: 0) {
            ForEach(results.indices, id: \.self) { i in
                let r = results[i]
                let (icon, width) = Self.icon(r.detail, isLastText: r.isLastText, fromId: change.from)
                SystemMessage(.icon(icon, width: width), contents: r.text) { button(r) }
            }
        }
    }

    @ViewBuilder func button(_ r: GroupChangeRenderer.Result) -> some View {
        let d = r.detail
        if d.type == "description", let text = d.description, !text.isEmpty {
            LegacyButton(i18n("icu:view"), size: .small, variant: .systemMessage) { viewDescription(text) }
        } else if r.isLastText, d.type == "admin-approval-bounce", areWeAdmin, let aci = d.aci, aci != ourAci,
                  change.from == nil || change.from == aci,
                  !(groupMemberships?.contains { $0.aci == aci } ?? false), !(groupBannedMemberships?.contains(aci) ?? false) {
            LegacyButton(i18n("icu:PendingRequests--block--button"), size: .small, variant: .systemMessage) { blockGroupLinkRequests(aci) }
        }
    }
}
