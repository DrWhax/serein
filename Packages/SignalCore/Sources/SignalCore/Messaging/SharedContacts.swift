// Shared contacts (DataMessage.Contact; upstream EmbeddedContactType): kept in the message's
// `contact` (upstream processContact's shape, the first contact only), the avatar a `contact`
// attachment of the message. Received, shown, and sent (enqueueSharedContactForSend).

import Foundation
import GRDB
import SignalProtos

/// A shared contact as stored and shown.
public struct SharedContactInfo: Sendable, Equatable {
    /// A phone number or email: `ContactFormType` 1 home, 2 mobile, 3 work, 4 custom.
    public struct Method: Sendable, Equatable {
        public var value: String
        public var type: Int
        public var label: String?
        public init(value: String, type: Int, label: String? = nil) {
            self.value = value
            self.type = type
            self.label = label
        }
    }

    /// `AddressType` 1 home, 2 work, 3 custom.
    public struct Address: Sendable, Equatable {
        public var type: Int
        public var label, street, pobox, neighborhood, city, region, postcode, country: String?
    }

    public var givenName, familyName, prefix, suffix, middleName, nickname: String?
    public var organization: String?
    public var numbers: [Method] = []
    public var emails: [Method] = []
    public var addresses: [Address] = []
    /// Their ACI, when the sender knew it (they are on Signal).
    public var aci: String?
    /// The sharer's nickname and note for them.
    public var signalNicknameGiven, signalNicknameFamily: String?
    public var note: String?
    public var avatarIsProfile = false
    /// The avatar (a `contact` attachment), filled in by the timeline query.
    public var avatar: MessageAttachment?
    /// How to message them (`resolveSharedContact`), filled in by the timeline query.
    public var resolution: SharedContacts.Resolution = .notOnSignal

    public init(givenName: String? = nil, familyName: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
    }

    /// `canShareContact`: a name and an ACI, or a number.
    public var canBeShared: Bool {
        let named = [givenName, familyName, nickname].contains { !($0 ?? "").isEmpty }
        return !numbers.isEmpty || (named && aci != nil)
    }
}

public enum SharedContacts {
    static func phoneType(_ raw: Int) -> Int { (1 ... 4).contains(raw) ? raw : 1 }
    static func addressType(_ raw: Int) -> Int { (1 ... 3).contains(raw) ? raw : 1 }

    /// `processContact`: the stored form of a received (or synced) contact; its avatar is stored
    /// apart, as a `contact` attachment.
    static func json(_ c: Signalservice_DataMessage.Contact) -> [String: Any] {
        var out: [String: Any] = [:]
        if c.hasAciBinary, let aci = StorageLocal.aci(binary: c.aciBinary, string: "") { out["aci"] = aci }
        if c.hasName {
            var n: [String: Any] = [:]
            for (k, v, has) in [("givenName", c.name.givenName, c.name.hasGivenName), ("familyName", c.name.familyName, c.name.hasFamilyName),
                                ("prefix", c.name.prefix, c.name.hasPrefix), ("suffix", c.name.suffix, c.name.hasSuffix),
                                ("middleName", c.name.middleName, c.name.hasMiddleName), ("nickname", c.name.nickname, c.name.hasNickname)] where has {
                n[k] = v
            }
            out["name"] = n
        }
        out["number"] = c.number.filter { !$0.value.isEmpty }.map { p -> [String: Any] in
            var m: [String: Any] = ["value": p.value, "type": phoneType(p.type.rawValue)]
            if p.hasLabel { m["label"] = p.label }
            return m
        }
        out["email"] = c.email.filter { !$0.value.isEmpty }.map { e -> [String: Any] in
            var m: [String: Any] = ["value": e.value, "type": phoneType(e.type.rawValue)]
            if e.hasLabel { m["label"] = e.label }
            return m
        }
        out["address"] = c.address.map { a -> [String: Any] in
            var m: [String: Any] = ["type": addressType(a.type.rawValue)]
            for (k, v, has) in [("label", a.label, a.hasLabel), ("street", a.street, a.hasStreet), ("pobox", a.pobox, a.hasPobox),
                                ("neighborhood", a.neighborhood, a.hasNeighborhood), ("city", a.city, a.hasCity), ("region", a.region, a.hasRegion),
                                ("postcode", a.postcode, a.hasPostcode), ("country", a.country, a.hasCountry)] where has {
                m[k] = v
            }
            return m
        }
        if c.hasOrganization { out["organization"] = c.organization }
        if c.hasAvatar { out["avatar"] = ["isProfile": c.avatar.isProfile] }
        if c.hasNickname { out["nickname"] = ["givenName": c.nickname.given, "familyName": c.nickname.family] }
        if c.hasNote { out["note"] = c.note }
        return out
    }

    /// A stored contact as the timeline shows it.
    static func info(_ json: [String: Any]) -> SharedContactInfo {
        var c = SharedContactInfo()
        let n = json["name"] as? [String: Any] ?? [:]
        c.givenName = n["givenName"] as? String
        c.familyName = n["familyName"] as? String
        c.prefix = n["prefix"] as? String
        c.suffix = n["suffix"] as? String
        c.middleName = n["middleName"] as? String
        c.nickname = n["nickname"] as? String
        c.organization = json["organization"] as? String
        func methods(_ k: String) -> [SharedContactInfo.Method] {
            (json[k] as? [[String: Any]] ?? []).compactMap { m in
                guard let v = m["value"] as? String, !v.isEmpty else { return nil }
                return .init(value: v, type: (m["type"] as? NSNumber)?.intValue ?? 1, label: m["label"] as? String)
            }
        }
        c.numbers = methods("number")
        c.emails = methods("email")
        c.addresses = (json["address"] as? [[String: Any]] ?? []).map { a in
            SharedContactInfo.Address(type: (a["type"] as? NSNumber)?.intValue ?? 1, label: a["label"] as? String, street: a["street"] as? String,
                                      pobox: a["pobox"] as? String, neighborhood: a["neighborhood"] as? String, city: a["city"] as? String,
                                      region: a["region"] as? String, postcode: a["postcode"] as? String, country: a["country"] as? String)
        }
        c.aci = json["aci"] as? String
        let nick = json["nickname"] as? [String: Any]
        c.signalNicknameGiven = nick?["givenName"] as? String
        c.signalNicknameFamily = nick?["familyName"] as? String
        c.note = json["note"] as? String
        c.avatarIsProfile = (json["avatar"] as? [String: Any])?["isProfile"] as? Bool ?? false
        return c
    }

    /// The stored form of a contact we send (`enqueueSharedContactForSend`).
    static func json(_ c: SharedContactInfo, hasAvatar: Bool) -> [String: Any] {
        var out: [String: Any] = [:]
        if let aci = c.aci { out["aci"] = aci }
        var n: [String: Any] = [:]
        for (k, v) in [("givenName", c.givenName), ("familyName", c.familyName), ("prefix", c.prefix), ("suffix", c.suffix),
                       ("middleName", c.middleName), ("nickname", c.nickname)] {
            if let v, !v.isEmpty { n[k] = v }
        }
        if !n.isEmpty { out["name"] = n }
        out["number"] = c.numbers.map { m -> [String: Any] in
            var o: [String: Any] = ["value": m.value, "type": phoneType(m.type)]
            if let l = m.label { o["label"] = l }
            return o
        }
        out["email"] = c.emails.map { m -> [String: Any] in
            var o: [String: Any] = ["value": m.value, "type": phoneType(m.type)]
            if let l = m.label { o["label"] = l }
            return o
        }
        if let org = c.organization, !org.isEmpty { out["organization"] = org }
        if hasAvatar { out["avatar"] = ["isProfile": c.avatarIsProfile] }
        if c.signalNicknameGiven != nil || c.signalNicknameFamily != nil {
            out["nickname"] = ["givenName": c.signalNicknameGiven ?? "", "familyName": c.signalNicknameFamily ?? ""]
        }
        if let note = c.note, !note.isEmpty { out["note"] = note }
        return out
    }

    /// The proto of a stored contact (`toContactProto`), with its uploaded avatar.
    static func proto(_ json: [String: Any], avatar: Signalservice_AttachmentPointer?) -> Signalservice_DataMessage.Contact {
        let c = info(json)
        var p = Signalservice_DataMessage.Contact()
        if let aci = c.aci, let bytes = StorageLocal.uuidBytes(aci) { p.aciBinary = bytes }
        if [c.givenName, c.familyName, c.prefix, c.suffix, c.middleName, c.nickname].contains(where: { $0 != nil }) {
            var n = Signalservice_DataMessage.Contact.Name()
            if let v = c.givenName { n.givenName = v }
            if let v = c.familyName { n.familyName = v }
            if let v = c.prefix { n.prefix = v }
            if let v = c.suffix { n.suffix = v }
            if let v = c.middleName { n.middleName = v }
            if let v = c.nickname { n.nickname = v }
            p.name = n
        }
        p.number = c.numbers.map { m in
            var x = Signalservice_DataMessage.Contact.Phone()
            x.value = m.value
            if let t = Signalservice_DataMessage.Contact.Phone.TypeEnum(rawValue: phoneType(m.type)) { x.type = t }
            if let l = m.label { x.label = l }
            return x
        }
        p.email = c.emails.map { m in
            var x = Signalservice_DataMessage.Contact.Email()
            x.value = m.value
            if let t = Signalservice_DataMessage.Contact.Email.TypeEnum(rawValue: phoneType(m.type)) { x.type = t }
            if let l = m.label { x.label = l }
            return x
        }
        if let org = c.organization { p.organization = org }
        if let avatar {
            var a = Signalservice_DataMessage.Contact.Avatar()
            a.avatar = avatar
            a.isProfile = c.avatarIsProfile
            p.avatar = a
        }
        if c.signalNicknameGiven != nil || c.signalNicknameFamily != nil {
            var nick = Signalservice_DataMessage.Contact.SignalNickname()
            nick.given = c.signalNicknameGiven ?? ""
            nick.family = c.signalNicknameFamily ?? ""
            p.nickname = nick
        }
        if let note = c.note { p.note = note }
        return p
    }
}

/// Someone the share-contact dialog offers (`isShareableContact`), with what would be shared
/// (`getShareContactDraft`).
public struct ShareContactCandidateInfo: Sendable, Equatable {
    public var conversationId: String
    public var title: String
    public var color: String
    public var about: String?
    /// The draft: name (`getName`), number (one CUSTOM entry), registered ACI, nickname, note.
    public var draft: SharedContactInfo
    /// `getAvatarOptions`: the profile avatar, then the system contact's.
    public var avatarOptions: [(file: LocalFile, isProfile: Bool)]

    public static func == (a: Self, b: Self) -> Bool {
        a.conversationId == b.conversationId && a.title == b.title && a.color == b.color && a.about == b.about && a.draft == b.draft
            && a.avatarOptions.map(\.file.path) == b.avatarOptions.map(\.file.path) && a.avatarOptions.map(\.isProfile) == b.avatarOptions.map(\.isProfile)
    }
}

extension SharedContacts {
    /// `SmartShareContactDialog`'s contacts: Signal connections (profile sharing or a system
    /// contact) with a number, or a name and a registered ACI; and anyone else with a number.
    /// Never ourselves, the recipient, or anyone blocked or removed.
    public static func candidates(_ db: Database, excluding conversationId: String, ourAci: String) throws -> [ShareContactCandidateInfo] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, json, name, serviceId, e164, profileName, profileFamilyName FROM conversations WHERE type = 'private' AND id != ?
            """, arguments: [conversationId])
        return try rows.compactMap { row -> ShareContactCandidateInfo? in
            let json = try MessageStore.jsonObject(row["json"] as String? ?? "{}")
            func s(_ k: String) -> String? {
                let v = (json[k] as? String) ?? (row.hasColumn(k) ? row[k] as String? : nil)
                return v.flatMap { $0.isEmpty ? nil : $0 }
            }
            let serviceId = s("serviceId"), e164 = s("e164")
            guard serviceId != ourAci, json["removalStage"] == nil else { return nil }
            if let serviceId, try MessageSender.isBlocked(db, serviceId: serviceId) { return nil }
            // getRegisteredAci: an ACI never found unregistered.
            let registeredAci = serviceId.flatMap { $0.hasPrefix("PNI:") || json["discoveredUnregisteredAt"] != nil ? nil : $0 }
            let inSystemContacts = s("systemGivenName") != nil || s("systemFamilyName") != nil || s("systemNickname") != nil || s("name") != nil
            let isConnection = serviceId != nil && (json["profileSharing"] as? Bool == true || inSystemContacts)
            if isConnection {
                // canShareContactFromConversation
                let named = s("systemGivenName") != nil || s("systemFamilyName") != nil || s("systemNickname") != nil || s("profileName") != nil
                guard e164 != nil || (named && registeredAci != nil) else { return nil }
            } else {
                guard e164 != nil else { return nil }
            }
            var d = SharedContactInfo()
            // getName: the system contact's name, its nickname, else the profile name.
            if s("systemGivenName") != nil || s("systemFamilyName") != nil {
                (d.givenName, d.familyName) = (s("systemGivenName"), s("systemFamilyName"))
            } else if let nick = s("systemNickname") {
                d.givenName = nick
            } else {
                (d.givenName, d.familyName) = (s("profileName"), s("profileFamilyName"))
            }
            if let e164 { d.numbers = [.init(value: e164, type: 4)] }
            d.aci = registeredAci
            (d.signalNicknameGiven, d.signalNicknameFamily) = (s("nicknameGivenName"), s("nicknameFamilyName"))
            d.note = s("note")
            let options = [LocalFile.from(json["profileAvatar"]).map { ($0, true) }, LocalFile.from(json["avatar"]).map { ($0, false) }]
                .compactMap { $0 }
            d.avatarIsProfile = options.first?.1 ?? false
            let title = ConversationQueries.titleNoDefault(row, json: json, kind: .private) ?? e164 ?? ""
            let color = s("color") ?? ConversationQueries.avatarColor(serviceId: serviceId, e164: e164, groupId: nil)
            return ShareContactCandidateInfo(conversationId: row["id"], title: title, color: color, about: s("about"), draft: d,
                                             avatarOptions: options.map { (file: $0.0, isProfile: $0.1) })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

extension SharedContacts {
    /// `SharedContactResolutionType`
    public enum Resolution: Sendable, Equatable {
        case existing(conversationId: String)
        case aci(String)
        case notOnSignal
    }

    /// `isConversationUnregistered`: no service id, or found unregistered in the last six hours.
    static func isUnregistered(serviceId: String?, _ json: [String: Any], now: Int64) -> Bool {
        guard let serviceId, !serviceId.isEmpty else { return true }
        guard let at = (json["discoveredUnregisteredAt"] as? NSNumber)?.int64Value, at > 0 else { return false }
        return now - at < 6 * 3600 * 1000
    }

    /// `resolveSharedContact`: their ACI's chat (none yet: the ACI), else a registered chat with
    /// one of their numbers, else not on Signal.
    public static func resolve(_ db: Database, _ c: SharedContactInfo, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Resolution {
        func lookup(_ sql: String, _ value: String) throws -> (String, Bool)? {
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [value]) else { return nil }
            let json = try MessageStore.jsonObject(row["json"] as String? ?? "{}")
            return (row["id"], isUnregistered(serviceId: row["serviceId"], json, now: now))
        }
        if let aci = c.aci {
            guard let (id, unregistered) = try lookup("SELECT id, json, serviceId FROM conversations WHERE type = 'private' AND serviceId = ?", aci) else {
                return .aci(aci)
            }
            return unregistered ? .notOnSignal : .existing(conversationId: id)
        }
        for n in c.numbers {
            if let (id, unregistered) = try lookup("SELECT id, json, serviceId FROM conversations WHERE type = 'private' AND e164 = ?", n.value), !unregistered {
                return .existing(conversationId: id)
            }
        }
        return .notOnSignal
    }
}

extension SharedContacts {
    /// `copyAvatarForMessage`: the avatar file shown in the dialog, sent as it is (its type
    /// sniffed, else JPEG).
    public static func avatarAttachment(_ data: Data) -> OutgoingAttachment {
        OutgoingAttachment(data: data, contentType: Stickers.sniffContentType(data) ?? "image/jpeg", fileName: nil)
    }
}
