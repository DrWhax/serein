// ContactRecord, GroupV2Record and AccountRecord: to*Record (local -> record) and merge*Record
// (remote -> local), ported from ts/services/storageRecordOps.preload.ts. We are always a
// linked device (`areWePrimaryDevice()` false). Payment, donation and backup fields of the
// AccountRecord are not used by this client but kept as items so write-back preserves them.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

/// `MergeResultType`
struct StorageMergeResult {
    var shouldDrop = false
    var needsProfileFetch: String? = nil
    var groupToUpdate: Data? = nil
    var details: [String] = []

    static func drop(_ why: String) -> StorageMergeResult { StorageMergeResult(shouldDrop: true, details: [why]) }
}

struct StorageMergeContext {
    var account: Account
    var version: UInt64
    var isFirstSync: Bool
    var now: Int64
    var messageQueueTime: Int64
    var binaryServiceIds: Bool
    var sender: MessageSender
}

enum StorageRecords {
    // MARK: small helpers

    static func string(_ json: [String: Any], _ key: String) -> String { json[key] as? String ?? "" }
    static func optString(_ json: [String: Any], _ key: String) -> String? {
        guard let s = json[key] as? String, !s.isEmpty else { return nil }
        return s
    }
    static func bool(_ json: [String: Any], _ key: String) -> Bool { json[key] as? Bool ?? false }
    static func int64(_ json: [String: Any], _ key: String) -> Int64? { (json[key] as? NSNumber)?.int64Value }
    static func set(_ json: inout [String: Any], _ key: String, _ value: String) { json[key] = value.isEmpty ? nil : value }

    /// `normalizeProfileName`
    static func normalizeName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func put<T: Encodable>(_ db: Database, _ key: String, _ value: T?) throws {
        if let value { try Items.set(db, key, value) } else { try Items.remove(db, key) }
    }

    // MARK: ContactRecord

    static func toContactRecord(_ db: Database, _ c: StorageLocal.ConversationRow, binary: Bool) throws -> Signalservice_ContactRecord {
        let j = c.json
        var r = Signalservice_ContactRecord()
        let serviceId = c.serviceId
        let aci = serviceId.flatMap { $0.hasPrefix("PNI:") ? nil : $0 }
        let pni = optString(j, "pni") ?? serviceId.flatMap { $0.hasPrefix("PNI:") ? $0 : nil }
        r.e164 = c.e164 ?? ""
        if let aci {
            if binary { r.aciBinary = StorageLocal.uuidBytes(aci) ?? Data() } else { r.aci = aci }
        }
        if let pni {
            let raw = String(pni.dropFirst(4))
            if binary { r.pniBinary = StorageLocal.uuidBytes(raw) ?? Data() } else { r.pni = raw }
        }
        r.username = string(j, "username")
        if let serviceId,
           let identity = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]).map(MessageStore.jsonObject),
           let key = (identity["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            r.identityKey = key
            switch VerifiedStatus(rawValue: identity["verified"] as? Int ?? 0) ?? .default {
            case .verified: r.identityState = .verified
            case .unverified: r.identityState = .unverified
            case .default: r.identityState = .default
            }
        }
        r.pniSignatureVerified = bool(j, "pniSignatureVerified")
        r.profileKey = (j["profileKey"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        r.givenName = string(j, "profileName")
        r.familyName = string(j, "profileFamilyName")
        if optString(j, "sharedGivenName") != nil || optString(j, "sharedFamilyName") != nil {
            r.sharedName.given = string(j, "sharedGivenName")
            r.sharedName.family = string(j, "sharedFamilyName")
        }
        if optString(j, "nicknameGivenName") != nil || optString(j, "nicknameFamilyName") != nil {
            r.nickname.given = string(j, "nicknameGivenName")
            r.nickname.family = string(j, "nicknameFamilyName")
        }
        r.note = string(j, "note")
        r.systemGivenName = string(j, "systemGivenName")
        r.systemFamilyName = string(j, "systemFamilyName")
        r.systemNickname = string(j, "systemNickname")
        let byId: (blocked: Bool, at: Int64?) = try serviceId.map { try BlockedList.serviceIds.blockedAt(db, $0) } ?? (false, nil)
        let byNumber: (blocked: Bool, at: Int64?) = try c.e164.map { try BlockedList.numbers.blockedAt(db, $0) } ?? (false, nil)
        r.blocked = byId.blocked || byNumber.blocked
        r.blockedAtTimestamp = UInt64(max(0, byId.at ?? byNumber.at ?? 0))
        r.hidden = j["removalStage"] != nil
        r.whitelisted = bool(j, "profileSharing")
        r.archived = bool(j, "isArchived")
        r.markedUnread = bool(j, "markedUnread")
        r.mutedUntilTimestamp = StorageLocal.muteToProto(int64(j, "muteExpiresAt"))
        r.notifyForCallsIfMuted = StorageLocal.toOptionalBool(j["notifyForCallsIfMuted"] as? Bool)
        r.showUnreadReminders = StorageLocal.toOptionalBool(j["showUnreadReminders"] as? Bool)
        if let color = j["colorFromPrimary"] as? Int, let c = Signalservice_AvatarColor(rawValue: color) { r.avatarColor = c }
        r.hideStory = bool(j, "hideStory")
        r.unregisteredAtTimestamp = UInt64(max(0, int64(j, "firstUnregisteredAt") ?? 0))
        try StorageLocal.attach(c.unknownFields, to: &r)
        return r
    }

    /// `mergeContactRecord`
    static func mergeContact(_ db: Database, _ c: Signalservice_ContactRecord, storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult {
        let aci = StorageLocal.aci(binary: c.aciBinary, string: c.aci)
        if aci == nil && (!c.aciBinary.isEmpty || !c.aci.isEmpty) { return .drop("invalid aci") }
        let pni = StorageLocal.pniString(binary: c.pniBinary, string: c.pni)
        let e164 = c.e164.isEmpty ? nil : c.e164
        guard let serviceId = aci ?? pni else { return .drop("no uuid") }
        if serviceId == ctx.account.aci || serviceId == ctx.account.pniServiceId { return .drop("our own uuid") }
        if serviceId == StorageLocal.signalAci { return .drop("signal release notes aci") }

        let id = try StorageLocal.contactConversation(db, aci: aci, pni: pni, e164: e164)
        guard let local = try StorageLocal.conversation(db, id: id), local.serviceId == serviceId else {
            return .drop("conversation serviceId mismatch")
        }
        var result = StorageMergeResult()
        var needsSync = false
        let j = local.json

        // Profile key
        let localKey = j["profileKey"] as? String
        let remoteKey = c.profileKey.isEmpty ? nil : c.profileKey.base64EncodedString()
        var setKey = false
        if let remoteKey {
            if ctx.isFirstSync || localKey == nil { setKey = true } else if localKey != remoteKey { needsSync = true }
        }

        // Profile name
        let remoteName = normalizeName(c.givenName), remoteFamily = normalizeName(c.familyName)
        let localName = optString(j, "profileName"), localFamily = optString(j, "profileFamilyName")
        var newName: (String, String?)? = nil
        if let remoteName, ctx.isFirstSync || (localName == nil && localFamily == nil) {
            newName = (remoteName, remoteFamily)
            result.needsProfileFetch = serviceId
        } else if (remoteName != nil && localName != nil && remoteName != localName)
                    || (remoteFamily != nil && localFamily != nil && remoteFamily != localFamily) {
            result.needsProfileFetch = serviceId
            needsSync = true
        }

        // Identity key + verified state
        let identityJSON = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]).map(MessageStore.jsonObject)
        let localIdentity = (identityJSON?["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }
        let haveRemoteKey = !c.identityKey.isEmpty
        let keysMatch = haveRemoteKey && localIdentity.map { SignalCrypto.constantTimeEqual($0, c.identityKey) } == true
        if haveRemoteKey, ctx.isFirstSync || localIdentity == nil || keysMatch, let identity = try? IdentityKey(bytes: c.identityKey) {
            let newVerified: VerifiedStatus = c.identityState == .verified ? .verified : c.identityState == .unverified ? .unverified : .default
            let oldVerified = VerifiedStatus(rawValue: identityJSON?["verified"] as? Int ?? 0) ?? .default
            if localIdentity != nil && !keysMatch {
                // `updateIdentityAfterSync` on a first sync with a different key: keychange.
                let devices = try Int.fetchAll(db, sql: "SELECT deviceId FROM sessions WHERE ourServiceId = ? AND serviceId = ?",
                                               arguments: [ctx.account.aci, serviceId])
                try ctx.sender.archive(db, serviceId: serviceId, devices: devices.map { UInt32($0) })
                try MessageStore.insertKeyChange(db, serviceId: serviceId)
            }
            if !keysMatch || oldVerified != newVerified {
                try ProtocolStore.setIdentity(db, serviceId: serviceId, key: identity.serialize(), verified: newVerified)
            }
            if localIdentity != nil, (oldVerified == .verified) != (newVerified == .verified) {
                try MessageStore.insert(db, .init(conversationId: id, type: "verified-change", body: "", sentAt: UInt64(ctx.now), source: nil,
                                                  sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                                  extra: ["verified": newVerified == .verified, "verifiedChanged": id, "local": false,
                                                          "readStatus": ReadStatus.read.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
            }
        } else if haveRemoteKey, localIdentity != nil, !keysMatch, aci != nil {
            result.needsProfileFetch = serviceId
            needsSync = true
        }

        let mutedUntil = StorageLocal.muteFromProto(c.mutedUntilTimestamp)
        try MessageStore.updateConversationJSON(db, conversationId: id) { json in
            if let e164 { json["e164"] = e164 }
            if aci != nil, let pni { json["pni"] = pni }
            if c.username.isEmpty { json["username"] = nil } else { json["username"] = c.username }
            if let (given, family) = newName {
                json["profileName"] = given
                json["profileFamilyName"] = family
            }
            // Not the primary: system names always follow the phone.
            set(&json, "systemGivenName", c.systemGivenName)
            set(&json, "systemFamilyName", c.systemFamilyName)
            set(&json, "systemNickname", c.systemNickname)
            set(&json, "nicknameGivenName", c.hasNickname ? c.nickname.given : "")
            set(&json, "nicknameFamilyName", c.hasNickname ? c.nickname.family : "")
            set(&json, "sharedGivenName", c.hasSharedName ? c.sharedName.given : "")
            set(&json, "sharedFamilyName", c.hasSharedName ? c.sharedName.family : "")
            set(&json, "note", c.note)
            json["pniSignatureVerified"] = c.pniSignatureVerified ? true : nil
            applyMessageRequestState(&json, blocked: c.blocked, whitelisted: c.whitelisted)
            StorageLocal.setUnknownFields(&json, StorageLocal.unknownFields(c))
            json["hideStory"] = c.hideStory
            json["isArchived"] = c.archived
            json["markedUnread"] = c.markedUnread
            json["notifyForCallsIfMuted"] = StorageLocal.fromOptionalBool(c.notifyForCallsIfMuted)
            json["showUnreadReminders"] = StorageLocal.fromOptionalBool(c.showUnreadReminders)
            json["storageID"] = storageID
            json["storageVersion"] = ctx.version
            json["needsStorageServiceSync"] = needsSync
            // removeContact / restoreContact
            if c.hidden { if json["removalStage"] == nil { json["removalStage"] = "justNotification" } } else { json["removalStage"] = nil }
            json["muteExpiresAt"] = mutedUntil
            // setRegistered / setUnregistered
            if c.unregisteredAtTimestamp == 0 {
                json["discoveredUnregisteredAt"] = nil
                json["firstUnregisteredAt"] = nil
            } else {
                if json["discoveredUnregisteredAt"] == nil { json["discoveredUnregisteredAt"] = ctx.now }
                if json["firstUnregisteredAt"] == nil { json["firstUnregisteredAt"] = Int64(min(c.unregisteredAtTimestamp, UInt64(Int64.max))) }
            }
            StorageLocal.applyAvatarColor(&json, has: c.hasAvatarColor, c.avatarColor.rawValue)
        }
        if let e164 { try db.execute(sql: "UPDATE conversations SET e164 = ? WHERE id = ?", arguments: [e164, id]) }
        if let (given, family) = newName {
            try db.execute(sql: "UPDATE conversations SET profileName = ?, profileFamilyName = ?, profileFullName = ? WHERE id = ?",
                           arguments: [given, family, [given, family].compactMap { $0 }.joined(separator: " "), id])
        }
        if setKey, c.profileKey.count == 32, try MessageStore.setProfileKey(db, serviceId: serviceId, c.profileKey) {
            result.needsProfileFetch = serviceId
        }
        try BlockedList.serviceIds.set(db, serviceId, blocked: c.blocked, at: c.blockedAtTimestamp > 0 ? Int64(c.blockedAtTimestamp) : nil)
        if !c.blocked, let e164 { try BlockedList.numbers.set(db, e164, blocked: false) }
        return result
    }

    /// `applyMessageRequestState` (BLOCK / ACCEPT / unblock, then disable sharing if not whitelisted).
    static func applyMessageRequestState(_ json: inout [String: Any], blocked: Bool, whitelisted: Bool) {
        if blocked {
            json["profileSharing"] = false
        } else if whitelisted {
            json["profileSharing"] = true
            json["messageRequestResponseType"] = 1   // ACCEPT
        }
        if !whitelisted { json["profileSharing"] = false }
    }

    // MARK: GroupV2Record

    static func toGroupV2Record(_ db: Database, _ c: StorageLocal.ConversationRow) throws -> Signalservice_GroupV2Record? {
        let j = c.json
        guard let mk = (j["masterKey"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        var r = Signalservice_GroupV2Record()
        r.masterKey = mk
        let blocked: (blocked: Bool, at: Int64?) = try c.groupId.map { try BlockedList.groups.blockedAt(db, $0) } ?? (false, nil)
        r.blocked = blocked.blocked
        r.blockedAtTimestamp = UInt64(max(0, blocked.at ?? 0))
        r.whitelisted = bool(j, "profileSharing")
        r.archived = bool(j, "isArchived")
        r.markedUnread = bool(j, "markedUnread")
        r.mutedUntilTimestamp = StorageLocal.muteToProto(int64(j, "muteExpiresAt"))
        let mentions = j["notifyForMentionsIfMuted"] as? Bool
        r.dontNotifyForMentionsIfMuted = mentions == false
        r.notifyForCallsIfMuted = StorageLocal.toOptionalBool(j["notifyForCallsIfMuted"] as? Bool)
        r.notifyForMentionsIfMuted = StorageLocal.toOptionalBool(mentions)
        r.notifyForRepliesIfMuted = StorageLocal.toOptionalBool(j["notifyForRepliesIfMuted"] as? Bool)
        r.showUnreadReminders = StorageLocal.toOptionalBool(j["showUnreadReminders"] as? Bool)
        r.hideStory = bool(j, "hideStory")
        if let color = j["colorFromPrimary"] as? Int, let c = Signalservice_AvatarColor(rawValue: color) { r.avatarColor = c }
        switch j["storySendMode"] as? String {
        case "Never": r.storySendMode = .disabled
        case "Always": r.storySendMode = .enabled
        default: r.storySendMode = .default
        }
        r.verifiedNameHash = (j["groupVerifiedNameHash"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        try StorageLocal.attach(c.unknownFields, to: &r)
        return r
    }

    /// `mergeGroupV2Record`
    static func mergeGroupV2(_ db: Database, _ g: Signalservice_GroupV2Record, storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult {
        guard g.masterKey.count == 32 else { throw StorageServiceError.recordTypeMismatch("GroupV2Record without master key") }
        let (id, groupId) = try MessageStore.groupConversation(db, masterKey: g.masterKey)
        let storySendMode: String
        switch g.storySendMode {
        case .default: storySendMode = "IfActive"
        case .disabled: storySendMode = "Never"
        case .enabled: storySendMode = "Always"
        case .UNRECOGNIZED(let v): throw StorageServiceError.recordTypeMismatch("story send mode \(v)")
        }
        var deletedAndTerminated = false
        try MessageStore.updateConversationJSON(db, conversationId: id) { json in
            json["hideStory"] = g.hideStory
            json["isArchived"] = g.archived
            json["markedUnread"] = g.markedUnread
            json["notifyForCallsIfMuted"] = StorageLocal.fromOptionalBool(g.notifyForCallsIfMuted)
            // resolveLegacyNotifyForMentionsIfMuted
            json["notifyForMentionsIfMuted"] = StorageLocal.fromOptionalBool(g.notifyForMentionsIfMuted) ?? (g.dontNotifyForMentionsIfMuted ? false : nil)
            json["notifyForRepliesIfMuted"] = StorageLocal.fromOptionalBool(g.notifyForRepliesIfMuted)
            json["showUnreadReminders"] = StorageLocal.fromOptionalBool(g.showUnreadReminders)
            json["storageID"] = storageID
            json["storageVersion"] = ctx.version
            json["storySendMode"] = storySendMode
            json["needsStorageServiceSync"] = false
            json["needsGroupUpdate"] = nil
            if !g.verifiedNameHash.isEmpty { json["groupVerifiedNameHash"] = g.verifiedNameHash.base64EncodedString() }
            json["muteExpiresAt"] = StorageLocal.muteFromProto(g.mutedUntilTimestamp)
            applyMessageRequestState(&json, blocked: g.blocked, whitelisted: g.whitelisted)
            StorageLocal.applyAvatarColor(&json, has: g.hasAvatarColor, g.avatarColor.rawValue)
            StorageLocal.setUnknownFields(&json, StorageLocal.unknownFields(g))
            deletedAndTerminated = (json["messagesDeleted"] as? Bool ?? false) && (json["terminated"] as? Bool ?? false)
        }
        try BlockedList.groups.set(db, groupId.base64EncodedString(), blocked: g.blocked, at: g.blockedAtTimestamp > 0 ? Int64(g.blockedAtTimestamp) : nil)
        var result = StorageMergeResult()
        if !deletedAndTerminated { result.groupToUpdate = g.masterKey }
        return result
    }

    // MARK: AccountRecord

    struct Payments: Codable { var enabled: Bool; var entropy: String }
    struct UsernameLink: Codable { var entropy: String; var serverId: String }
    struct NotificationProfileOverride: Codable {
        struct Enabled: Codable { var profileId: String; var endsAtMs: Int64? }
        var disabledAtMs: Int64?
        var enabled: Enabled?
    }

    static func toAccountRecord(_ db: Database, account: Account, binary: Bool) throws -> Signalservice_AccountRecord {
        let ourId = try StorageLocal.ourConversation(db, account: account)
        let our = try StorageLocal.conversation(db, id: ourId)!
        let j = our.json
        var r = Signalservice_AccountRecord()
        r.profileKey = (try Items.get(db, "profileKey", as: String.self)).flatMap { Data(base64Encoded: $0) } ?? Data()
        r.givenName = string(j, "profileName")
        r.familyName = string(j, "profileFamilyName")
        r.avatarURLPath = try Items.get(db, "avatarUrl", as: String.self) ?? ""
        r.username = string(j, "username")
        r.noteToSelfArchived = bool(j, "isArchived")
        r.noteToSelfMarkedUnread = bool(j, "markedUnread")
        r.readReceipts = try Items.get(db, "read-receipt-setting", as: Bool.self) ?? false
        r.sealedSenderIndicators = try Items.get(db, "sealedSenderIndicators", as: Bool.self) ?? false
        r.typingIndicators = try Items.get(db, "typingIndicators", as: Bool.self) ?? false
        r.linkPreviews = try Items.get(db, "linkPreviews", as: Bool.self) ?? false
        if let p = try Items.get(db, "payments", as: Payments.self) {
            r.payments.enabled = p.enabled
            r.payments.entropy = Data(base64Encoded: p.entropy) ?? Data()
        }
        r.preferContactAvatars = try Items.get(db, "preferContactAvatars", as: Bool.self) ?? false
        let emoji = try Items.get(db, "preferredReactionEmoji", as: [String].self) ?? []
        if canSyncReactionEmoji(emoji) { r.preferredReactionEmoji = emoji }
        r.universalExpireTimer = UInt32(clamping: try Items.get(db, "universalExpireTimer", as: Int.self) ?? 0)
        r.phoneNumberSharingMode = try Items.get(db, "phoneNumberSharingMode", as: String.self) == "Everybody" ? .everybody : .nobody
        r.unlistedPhoneNumber = try Items.get(db, "phoneNumberDiscoverability", as: String.self) == "NotDiscoverable"
        r.pinnedConversations = try (Items.get(db, "pinnedConversationIds", as: [String].self) ?? []).compactMap { id in
            guard let c = try StorageLocal.conversation(db, id: id) else { return nil }
            var p = Signalservice_AccountRecord.PinnedConversation()
            if c.type == "private" {
                guard let serviceId = c.serviceId else { return nil }
                if serviceId == StorageLocal.signalAci { p.identifier = .releaseNotes(.init()); return p }
                var contact = Signalservice_AccountRecord.PinnedConversation.Contact()
                if binary { contact.serviceIDBinary = StorageLocal.serviceIdBinary(serviceId) ?? Data() } else { contact.serviceID = serviceId }
                contact.e164 = c.e164 ?? ""
                p.identifier = .contact(contact)
            } else {
                guard let mk = (c.json["masterKey"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
                p.identifier = .groupMasterKey(mk)
            }
            return p
        }
        if let id = try Items.get(db, "subscriberId", as: String.self).flatMap({ Data(base64Encoded: $0) }), !id.isEmpty { r.donorSubscriberID = id }
        r.donorSubscriberCurrencyCode = try Items.get(db, "subscriberCurrencyCode", as: String.self) ?? ""
        r.donorSubscriptionManuallyCancelled = try Items.get(db, "donorSubscriptionManuallyCancelled", as: Bool.self) ?? false
        if let data = try Items.get(db, "backupsSubscriberData", as: String.self).flatMap({ Data(base64Encoded: $0) }) {
            r.backupSubscriberData = try Signalservice_AccountRecord.IAPSubscriberData(serializedBytes: data)
        }
        if let tier = try Items.get(db, "backupTier", as: UInt64.self) { r.backupTier = tier }
        r.displayBadgesOnProfile = try Items.get(db, "displayBadgesOnProfile", as: Bool.self) ?? false
        r.keepMutedChatsArchived = try Items.get(db, "keepMutedChatsArchived", as: Bool.self) ?? false
        r.unreadBadgeType = try Items.get(db, "unreadCountBadgeType", as: String.self) == "unread-chats" ? .unreadChats : .unreadMessages
        r.notifyForCallsIfMuted = StorageLocal.toOptionalBool(try Items.get(db, "notifyForCallsIfMuted", as: Bool.self))
        r.notifyForMentionsIfMuted = StorageLocal.toOptionalBool(try Items.get(db, "notifyForMentionsIfMuted", as: Bool.self))
        r.notifyForRepliesIfMuted = StorageLocal.toOptionalBool(try Items.get(db, "notifyForRepliesIfMuted", as: Bool.self))
        r.notifyWhenContactJoins = StorageLocal.toOptionalBool(try Items.get(db, "notifyWhenContactJoins", as: Bool.self))
        r.showUnreadReminders = StorageLocal.toOptionalBool(try Items.get(db, "showUnreadReminders", as: Bool.self))
        r.hasSetMyStoriesPrivacy_p = try Items.get(db, "hasSetMyStoriesPrivacy", as: Bool.self) ?? false
        r.hasViewedOnboardingStory_p = try Items.get(db, "hasViewedOnboardingStory", as: Bool.self) ?? false
        r.hasCompletedUsernameOnboarding_p = try Items.get(db, "hasCompletedUsernameOnboarding", as: Bool.self) ?? false
        r.hasSeenGroupStoryEducationSheet_p = try Items.get(db, "hasSeenGroupStoryEducationSheet", as: Bool.self) ?? false
        r.hasSeenAdminDeleteEducationDialog_p = try Items.get(db, "hasSeenAdminDeleteEducationDialog", as: Bool.self) ?? false
        r.includeMutedChatsInBadge = StorageLocal.toOptionalBool(try Items.get(db, "badge-count-muted-conversations", as: Bool.self))
        r.reactionNotifications = StorageLocal.toOptionalBool(try Items.get(db, "reaction-notification", as: Bool.self))
        if let color = j["colorFromPrimary"] as? Int, let c = Signalservice_AvatarColor(rawValue: color) { r.avatarColor = c }
        r.automaticKeyVerificationDisabled = try Items.get(db, "hasKeyTransparencyDisabled", as: Bool.self) == true
        r.storiesDisabled = try Items.get(db, "hasStoriesDisabled", as: Bool.self) == true
        switch try Items.get(db, "storyViewReceiptsEnabled", as: Bool.self) {
        case true?: r.storyViewReceiptsEnabled = .enabled
        case false?: r.storyViewReceiptsEnabled = .disabled
        case nil: r.storyViewReceiptsEnabled = .unset
        }
        if let link = try Items.get(db, "usernameLink", as: UsernameLink.self),
           let entropy = Data(base64Encoded: link.entropy), let server = Data(base64Encoded: link.serverId), !entropy.isEmpty, !server.isEmpty {
            r.usernameLink.entropy = entropy
            r.usernameLink.serverID = server
            r.usernameLink.color = .init(rawValue: try Items.get(db, "usernameLinkColor", as: Int.self) ?? 0) ?? .unknown
        }
        let syncDisabled = try Items.get(db, "notificationProfileSyncDisabled", as: Bool.self) ?? false
        let override = try Items.get(db, syncDisabled ? "notificationProfileOverrideFromPrimary" : "notificationProfileOverride",
                                     as: NotificationProfileOverride.self)
        if let at = override?.disabledAtMs, at > 0 {
            r.notificationProfileManualOverride.override = .disabledAtTimestampMs(UInt64(at))
        } else if let enabled = override?.enabled, let id = Data(hex: enabled.profileId) {
            var e = Signalservice_AccountRecord.NotificationProfileManualOverride.ManuallyEnabled()
            e.id = id
            if let end = enabled.endsAtMs, end > 0 { e.endAtTimestampMs = UInt64(end) }
            r.notificationProfileManualOverride.override = .enabled(e)
        }
        r.notificationProfileSyncDisabled = syncDisabled
        // The release notes chat: no Signal conversation here, its state is kept as items.
        let notes = try Items.get(db, "releaseNotesChat", as: [String: Int64].self) ?? [:]
        r.releaseNotesChatArchived = (notes["isArchived"] ?? 0) != 0
        r.releaseNotesChatMarkedUnread = (notes["markedUnread"] ?? 0) != 0
        r.releaseNotesChatMutedUntilTimestamp = StorageLocal.muteToProto(notes["muteExpiresAt"])
        let notesBlocked = try Items.get(db, "releaseNotesChatBlocked", as: Bool.self) ?? false
        r.releaseNotesChatBlocked = notesBlocked
        if notesBlocked, let at = try Items.get(db, "releaseNotesChatBlockedAt", as: Int64.self), at > 0 { r.releaseNotesChatBlockedAt = UInt64(at) }
        try StorageLocal.attach(our.unknownFields, to: &r)
        return r
    }

    /// `preferredReactionEmoji.canBeSynced`
    static func canSyncReactionEmoji(_ e: [String]) -> Bool { e.count == 6 || (!e.isEmpty && e.count <= 6) }

    /// `mergeAccountRecord`
    static func mergeAccount(_ db: Database, _ a: Signalservice_AccountRecord, storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult {
        var result = StorageMergeResult()
        try Items.set(db, "read-receipt-setting", a.readReceipts)
        try Items.set(db, "sealedSenderIndicators", a.sealedSenderIndicators)
        try Items.set(db, "typingIndicators", a.typingIndicators)
        try Items.set(db, "linkPreviews", a.linkPreviews)
        try Items.set(db, "preferContactAvatars", a.preferContactAvatars)
        if canSyncReactionEmoji(a.preferredReactionEmoji) { try Items.set(db, "preferredReactionEmoji", a.preferredReactionEmoji) }
        try Items.set(db, "universalExpireTimer", Int(a.universalExpireTimer))
        switch a.phoneNumberSharingMode {
        case .unknown, .nobody: try Items.set(db, "phoneNumberSharingMode", "Nobody")
        default: try Items.set(db, "phoneNumberSharingMode", "Everybody")
        }
        try Items.set(db, "phoneNumberDiscoverability", a.unlistedPhoneNumber ? "NotDiscoverable" : "Discoverable")

        // Pinned conversations
        let localPinned = Set(try String.fetchAll(db, sql: "SELECT id FROM conversations WHERE json ->> '$.isPinned' = 1"))
            .union(try Items.get(db, "pinnedConversationIds", as: [String].self) ?? [])
        var remotePinned: [String] = []
        for p in a.pinnedConversations {
            switch p.identifier {
            case .contact(let c):
                if let s = StorageLocal.serviceId(binary: c.serviceIDBinary, string: c.serviceID) {
                    remotePinned.append(try StorageLocal.contactConversation(db, aci: s.hasPrefix("PNI:") ? nil : s, pni: s.hasPrefix("PNI:") ? s : nil,
                                                                              e164: c.e164.isEmpty ? nil : c.e164))
                } else if !c.e164.isEmpty, let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND e164 = ?",
                                                                       arguments: [c.e164]) {
                    remotePinned.append(id)
                }
            case .groupMasterKey(let mk):
                if let keys = try? GroupKeys(masterKey: mk),
                   let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [keys.groupIdBase64]) {
                    remotePinned.append(id)
                }
            case .releaseNotes, .legacyGroupID, .none:
                continue
            }
        }
        for id in localPinned where !remotePinned.contains(id) {
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["isPinned"] = false }
        }
        for id in remotePinned {
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["isPinned"] = true; $0["isArchived"] = false }
        }
        try Items.set(db, "pinnedConversationIds", remotePinned)

        // Kept for write-back only (payments, donations and backups are not part of this client).
        if !a.donorSubscriberID.isEmpty { try Items.set(db, "subscriberId", a.donorSubscriberID.base64EncodedString()) }
        if !a.donorSubscriberCurrencyCode.isEmpty { try Items.set(db, "subscriberCurrencyCode", a.donorSubscriberCurrencyCode) }
        try Items.set(db, "donorSubscriptionManuallyCancelled", a.donorSubscriptionManuallyCancelled)
        let subscriberData: Data? = a.hasBackupSubscriberData ? try a.backupSubscriberData.serializedBytes() : nil
        try put(db, "backupsSubscriberData", subscriberData?.base64EncodedString())
        try put(db, "backupTier", a.hasBackupTier ? a.backupTier : nil)
        try put(db, "payments", a.hasPayments ? Payments(enabled: a.payments.enabled, entropy: a.payments.entropy.base64EncodedString()) : nil)

        try Items.set(db, "displayBadgesOnProfile", a.displayBadgesOnProfile)
        try Items.set(db, "keepMutedChatsArchived", a.keepMutedChatsArchived)
        try put(db, "notifyForCallsIfMuted", StorageLocal.fromOptionalBool(a.notifyForCallsIfMuted))
        try put(db, "notifyForMentionsIfMuted", StorageLocal.fromOptionalBool(a.notifyForMentionsIfMuted))
        try put(db, "notifyForRepliesIfMuted", StorageLocal.fromOptionalBool(a.notifyForRepliesIfMuted))
        try put(db, "notifyWhenContactJoins", StorageLocal.fromOptionalBool(a.notifyWhenContactJoins))
        try put(db, "showUnreadReminders", StorageLocal.fromOptionalBool(a.showUnreadReminders))
        try Items.set(db, "unreadCountBadgeType", a.unreadBadgeType == .unreadChats ? "unread-chats" : "unread-messages")
        try Items.set(db, "hasSetMyStoriesPrivacy", a.hasSetMyStoriesPrivacy_p)
        try Items.set(db, "hasViewedOnboardingStory", a.hasViewedOnboardingStory_p)
        try Items.set(db, "hasCompletedUsernameOnboarding", a.hasCompletedUsernameOnboarding_p)
        try Items.set(db, "hasSeenGroupStoryEducationSheet", a.hasSeenGroupStoryEducationSheet_p)
        try Items.set(db, "hasSeenAdminDeleteEducationDialog", a.hasSeenAdminDeleteEducationDialog_p)
        try Items.set(db, "badge-count-muted-conversations", StorageLocal.fromOptionalBool(a.includeMutedChatsInBadge) ?? false)
        try Items.set(db, "reaction-notification", StorageLocal.fromOptionalBool(a.reactionNotifications) ?? true)
        try Items.set(db, "hasKeyTransparencyDisabled", a.automaticKeyVerificationDisabled)
        try Items.set(db, "hasStoriesDisabled", a.storiesDisabled)
        switch a.storyViewReceiptsEnabled {
        case .enabled: try Items.set(db, "storyViewReceiptsEnabled", true)
        case .disabled: try Items.set(db, "storyViewReceiptsEnabled", false)
        default: break
        }
        if !a.usernameLink.entropy.isEmpty, !a.usernameLink.serverID.isEmpty {
            let old = try Items.get(db, "usernameLink", as: UsernameLink.self)
            if try Items.get(db, "usernameLinkCorrupted", as: Bool.self) == true,
               old?.entropy != a.usernameLink.entropy.base64EncodedString() || old?.serverId != a.usernameLink.serverID.base64EncodedString() {
                try Items.remove(db, "usernameLinkCorrupted")
            }
            let color = a.usernameLink.color
            let known = Signalservice_AccountRecord.UsernameLink.Color.allCases.contains(color)
            try Items.set(db, "usernameLinkColor", known ? color.rawValue : 0)
            try Items.set(db, "usernameLink", UsernameLink(entropy: a.usernameLink.entropy.base64EncodedString(),
                                                          serverId: a.usernameLink.serverID.base64EncodedString()))
        } else {
            try Items.remove(db, "usernameLinkColor")
            try Items.remove(db, "usernameLink")
        }
        try Items.set(db, "notificationProfileSyncDisabled", a.notificationProfileSyncDisabled)
        var override: NotificationProfileOverride? = nil
        switch a.notificationProfileManualOverride.override {
        case .enabled(let e) where !e.id.isEmpty:
            override = .init(disabledAtMs: nil, enabled: .init(profileId: e.id.hexString, endsAtMs: e.endAtTimestampMs > 0 ? Int64(e.endAtTimestampMs) : nil))
        case .disabledAtTimestampMs(let at) where at > 0:
            override = .init(disabledAtMs: Int64(at), enabled: nil)
        default:
            override = nil
        }
        try put(db, a.notificationProfileSyncDisabled ? "notificationProfileOverrideFromPrimary" : "notificationProfileOverride", override)

        // Our conversation
        let ourId = try StorageLocal.ourConversation(db, account: ctx.account)
        if a.profileKey.count == 32 {
            let old = try Items.get(db, "profileKey", as: String.self)
            let new = a.profileKey.base64EncodedString()
            if old != new {
                try Items.set(db, "profileKey", new)
                result.needsProfileFetch = ctx.account.aci
            }
            try MessageStore.updateConversationJSON(db, conversationId: ourId) { $0["profileKey"] = new }
        }
        let given = normalizeName(a.givenName), family = normalizeName(a.familyName)
        try MessageStore.updateConversationJSON(db, conversationId: ourId) { json in
            json["isArchived"] = a.noteToSelfArchived
            json["markedUnread"] = a.noteToSelfMarkedUnread
            json["storageID"] = storageID
            json["storageVersion"] = ctx.version
            json["needsStorageServiceSync"] = false
            json["username"] = a.username.isEmpty ? nil : a.username
            json["profileName"] = given
            json["profileFamilyName"] = family
            StorageLocal.applyAvatarColor(&json, has: a.hasAvatarColor, a.avatarColor.rawValue)
            StorageLocal.setUnknownFields(&json, StorageLocal.unknownFields(a))
        }
        try db.execute(sql: "UPDATE conversations SET profileName = ?, profileFamilyName = ?, profileFullName = ? WHERE id = ?",
                       arguments: [given, family, given.map { [$0, family].compactMap { $0 }.joined(separator: " ") }, ourId])
        if a.username.isEmpty { try Items.remove(db, "username") } else { try Items.set(db, "username", a.username) }
        try put(db, "avatarUrl", a.avatarURLPath.isEmpty ? nil : a.avatarURLPath)

        var notes = try Items.get(db, "releaseNotesChat", as: [String: Int64].self) ?? [:]
        if a.hasReleaseNotesChatArchived { notes["isArchived"] = a.releaseNotesChatArchived ? 1 : 0 }
        if a.hasReleaseNotesChatMarkedUnread { notes["markedUnread"] = a.releaseNotesChatMarkedUnread ? 1 : 0 }
        if a.hasReleaseNotesChatMutedUntilTimestamp { notes["muteExpiresAt"] = StorageLocal.muteFromProto(a.releaseNotesChatMutedUntilTimestamp) }
        try Items.set(db, "releaseNotesChat", notes)
        if a.hasReleaseNotesChatBlocked {
            try Items.set(db, "releaseNotesChatBlocked", a.releaseNotesChatBlocked)
            try put(db, "releaseNotesChatBlockedAt", a.releaseNotesChatBlocked && a.releaseNotesChatBlockedAt > 0 ? Int64(a.releaseNotesChatBlockedAt) : nil)
        }
        return result
    }
}
