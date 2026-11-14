// A message backup's frames into the database (services/backups import.preload.ts,
// BackupImportStream), in upstream's shapes: conversations and messages as
// ConversationAttributesType / MessageAttributesType JSON, attachments as message_attachments
// rows that download when viewed (transit tier), reactions in their table too.
//
// Covered: AccountData (profile, username and link, settings), Self, contacts (identity keys,
// blocked, visibility, registration), groups (snapshot, members, access, blocked), distribution
// lists, chats (archive, pin, timer, mute, marked unread), chat items — standard messages
// (text and ranges, attachments, long text, link previews, quotes, reactions, edits), contact
// cards, stickers, view-once, remote and admin deletes, polls, direct story text replies, and
// updates (simple ones, timer, profile and learned-profile changes, merges, switchovers, calls
// with their history, group changes, pins, poll ends) — installed sticker packs, chat folders
// and notification profiles. Dropped as upstream: the release notes chat, expired messages.
// Not imported (no payments, donations or backups here): payments, gift badges, backup and
// donation subscriber data, custom chat colours and wallpapers, call links and ad hoc calls.
// A frame that fails is counted and skipped; AccountData failing ends the import.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public struct BackupImportResult: Sendable, Equatable {
    public var conversations = 0
    public var messages = 0
    public var frameErrors = 0
}

struct BackupImporter {
    let db: Database
    let account: Account
    let now: Int64

    struct Recipient {
        var conversationId: String
        var serviceId: String?
        var e164: String?
        var isGroup = false
        var groupId: String?
    }
    var recipients: [UInt64: Recipient] = [:]
    var chats: [UInt64: String] = [:]
    var releaseNotesRecipient: UInt64?
    var releaseNotesChat: UInt64?
    /// Conversations in progress (written at the end): id → attributes.
    var conversations: [String: [String: Any]] = [:]
    var pinned: [(UInt32, String)] = []
    var folderPosition: Int64 = 0
    var sawAccount = false
    var result = BackupImportResult()
    let ourId: String

    init(db: Database, account: Account, now: Int64) throws {
        self.db = db
        self.account = account
        self.now = now
        ourId = try StorageLocal.ourConversation(db, account: account)
        conversations[ourId] = try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [ourId]) ?? "{}")
    }

    static func aci(_ b: Data) -> String? { UUID(data: b)?.uuidString.lowercased() }
    static func serviceId(_ b: Data) -> String? { try? ServiceId.parseFrom(serviceIdBinary: b).serviceIdString }
    static func ms(_ v: UInt64) -> Int64? { v == 0 || v > UInt64(Int64.max) ? nil : Int64(v) }

    struct Failure: Error, CustomStringConvertible { var description: String }
    static func check(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw Failure(description: what()) } }

    // MARK: frames

    mutating func process(_ frame: BackupProto_Frame) throws {
        switch frame.item {
        case .account(let a):
            try fromAccount(a)      // failing here is fatal
            return
        case nil:
            result.frameErrors += 1
            return
        default:
            break
        }
        do {
            switch frame.item {
            case .recipient(let r): try fromRecipient(r)
            case .chat(let c): try fromChat(c)
            case .chatItem(let i):
                try Self.check(sawAccount, "chat item before AccountData")
                try fromChatItem(i)
            case .installedStickerPack(let p): try fromStickerPack(p)
            case .notificationProfile(let p): try fromNotificationProfile(p)
            case .chatFolder(let f): try fromChatFolder(f)
            case .adHocCall: break     // call links are not imported
            case .account, nil: break
            }
        } catch {
            result.frameErrors += 1
        }
    }

    /// Writes the conversations and the pinned list.
    mutating func finish() throws {
        for (id, var attrs) in conversations {
            attrs["id"] = id
            try Self.writeConversation(db, attrs)
        }
        result.conversations = conversations.count
        let order = pinned.sorted { $0.0 < $1.0 }.map(\.1)
        if !order.isEmpty { try Items.set(db, "pinnedConversationIds", order) }
    }

    static func writeConversation(_ db: Database, _ c: [String: Any]) throws {
        let id = c["id"] as? String ?? UUID().uuidString.lowercased()
        let type = c["type"] as? String ?? "private"
        let given = c["profileName"] as? String, family = c["profileFamilyName"] as? String
        let full = [given, family].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let members = (c["membersV2"] as? [[String: Any]])?.compactMap { $0["aci"] as? String }.joined(separator: " ")
        try db.execute(sql: """
            INSERT INTO conversations (id, json, active_at, type, members, name, profileName, profileFamilyName, profileFullName, e164, serviceId,
              groupId, expireTimerVersion)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET json = excluded.json, active_at = excluded.active_at, type = excluded.type, members = excluded.members,
              name = excluded.name, profileName = excluded.profileName, profileFamilyName = excluded.profileFamilyName,
              profileFullName = excluded.profileFullName, e164 = excluded.e164, serviceId = excluded.serviceId, groupId = excluded.groupId,
              expireTimerVersion = excluded.expireTimerVersion
            """, arguments: [id, try MessageStore.jsonString(c), (c["active_at"] as? NSNumber)?.int64Value, type, members, c["name"] as? String,
                             given, family, full.isEmpty ? nil : full, c["e164"] as? String, c["serviceId"] as? String, c["groupId"] as? String,
                             (c["expireTimerVersion"] as? NSNumber)?.intValue ?? 1])
    }

    // MARK: account

    mutating func fromAccount(_ a: BackupProto_AccountData) throws {
        try Self.check(!sawAccount, "duplicate AccountData")
        try Self.check(!a.profileKey.isEmpty, "missing profile key")
        sawAccount = true
        var me = conversations[ourId] ?? [:]
        try Items.set(db, "profileKey", a.profileKey.base64EncodedString())
        me["profileKey"] = a.profileKey.base64EncodedString()
        if let key = try? ProfileKey(contents: a.profileKey) { me["accessKey"] = key.deriveAccessKey().base64EncodedString() }
        if a.hasUsername { me["username"] = a.username }
        if a.hasUsernameLink, !a.usernameLink.entropy.isEmpty, !a.usernameLink.serverID.isEmpty {
            try Items.set(db, "usernameLink", ["entropy": a.usernameLink.entropy.base64EncodedString(),
                                               "serverId": a.usernameLink.serverID.base64EncodedString()])
            try Items.set(db, "usernameLinkColor", a.usernameLink.color.rawValue)
        }
        me["profileName"] = a.givenName
        me["profileFamilyName"] = a.familyName
        if !a.bioText.isEmpty { me["about"] = a.bioText }
        if !a.bioEmoji.isEmpty { me["aboutEmoji"] = a.bioEmoji }
        if !a.avatarURLPath.isEmpty { try Items.set(db, "avatarUrl", a.avatarURLPath) }
        let s = a.accountSettings
        try Items.set(db, "read-receipt-setting", s.readReceipts)
        try Items.set(db, "sealedSenderIndicators", s.sealedSenderIndicators)
        try Items.set(db, "typingIndicators", s.typingIndicators)
        try Items.set(db, "linkPreviews", s.linkPreviews)
        try Items.set(db, "preferContactAvatars", s.preferContactAvatars)
        if s.universalExpireTimerSeconds > 0 { try Items.set(db, "universalExpireTimer", Int(s.universalExpireTimerSeconds)) }
        try Items.set(db, "displayBadgesOnProfile", s.displayBadgesOnProfile)
        try Items.set(db, "keepMutedChatsArchived", s.keepMutedChatsArchived)
        try Items.set(db, "hasSetMyStoriesPrivacy", s.hasSetMyStoriesPrivacy_p)
        try Items.set(db, "hasViewedOnboardingStory", s.hasViewedOnboardingStory_p)
        try Items.set(db, "hasStoriesDisabled", s.storiesDisabled)
        if s.hasStoryViewReceiptsEnabled { try Items.set(db, "storyViewReceiptsEnabled", s.storyViewReceiptsEnabled) }
        try Items.set(db, "hasCompletedUsernameOnboarding", s.hasCompletedUsernameOnboarding_p)
        try Items.set(db, "hasSeenGroupStoryEducationSheet", s.hasSeenGroupStoryEducationSheet_p)
        try Items.set(db, "preferredReactionEmoji", s.preferredReactionEmoji)
        try Items.set(db, "phoneNumberSharingMode", s.phoneNumberSharingMode == .everybody ? "Everybody" : "Nobody")
        try Items.set(db, "phoneNumberDiscoverability", s.notDiscoverableByPhoneNumber ? "NotDiscoverable" : "Discoverable")
        try Items.set(db, "sent-media-quality", s.defaultSentMediaQuality == .high ? "high" : "standard")
        conversations[ourId] = me
    }

    // MARK: recipients

    mutating func fromRecipient(_ r: BackupProto_Recipient) throws {
        switch r.destination {
        case .contact(let c):
            let (id, attrs) = try fromContact(c)
            conversations[id] = attrs
            recipients[r.id] = Recipient(conversationId: id, serviceId: attrs["serviceId"] as? String, e164: attrs["e164"] as? String)
        case .group(let g):
            let (id, attrs) = try fromGroup(g)
            conversations[id] = attrs
            recipients[r.id] = Recipient(conversationId: id, isGroup: true, groupId: attrs["groupId"] as? String)
        case .self_p(let s):
            if s.hasAvatarColor { conversations[ourId]?["color"] = Self.avatarColor(s.avatarColor) }
            recipients[r.id] = Recipient(conversationId: ourId, serviceId: account.aci, e164: account.number)
        case .releaseNotes:
            try Self.check(releaseNotesRecipient == nil, "duplicate release notes")
            releaseNotesRecipient = r.id
        case .distributionList(let d):
            try fromDistributionList(d)
        case .callLink, nil:
            break
        }
    }

    /// Upstream's color names (AvatarColorType) by BackupProto_AvatarColor.
    static func avatarColor(_ c: BackupProto_AvatarColor) -> String {
        "A\(100 + 10 * (c.rawValue % 12) + 10)"
    }

    func existingConversation(serviceId: String?, e164: String?, groupId: String? = nil) throws -> String? {
        if let groupId { return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [groupId]) }
        if let serviceId, let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [serviceId]) { return id }
        if let e164 { return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE e164 = ? AND type = 'private'", arguments: [e164]) }
        return nil
    }

    mutating func fromContact(_ c: BackupProto_Contact) throws -> (String, [String: Any]) {
        try Self.check(c.hasAci || c.hasPni || c.hasE164, "contact without aci, pni or e164")
        let aci = c.hasAci ? Self.aci(c.aci) : nil
        let pni = c.hasPni ? Self.aci(c.pni).map { "PNI:\($0)" } : nil
        let e164 = c.hasE164 ? "+\(c.e164)" : nil
        let serviceId = aci ?? pni
        let id = try existingConversation(serviceId: serviceId, e164: e164) ?? UUID().uuidString.lowercased()
        var attrs = conversations[id] ?? [:]
        attrs.merge(["id": id, "type": "private", "version": 2, "expireTimerVersion": 1, "sealedSender": 0, "unreadCount": 0,
                     "messageCount": 0, "sentMessageCount": 0, "profileSharing": c.profileSharing, "hideStory": c.hideStory]) { _, new in new }
        if let serviceId { attrs["serviceId"] = serviceId }
        if let pni { attrs["pni"] = pni }
        if let e164 { attrs["e164"] = e164 }
        switch c.visibility {
        case .hidden: attrs["removalStage"] = "justNotification"
        case .hiddenMessageRequest: attrs["removalStage"] = "messageRequest"
        default: attrs["removalStage"] = nil
        }
        if c.hasProfileKey, !c.profileKey.isEmpty {
            attrs["profileKey"] = c.profileKey.base64EncodedString()
            if let key = try? ProfileKey(contents: c.profileKey) { attrs["accessKey"] = key.deriveAccessKey().base64EncodedString() }
        }
        func set(_ key: String, _ value: String, _ present: Bool = true) { if present, !value.isEmpty { attrs[key] = value } }
        set("profileName", c.profileGivenName, c.hasProfileGivenName)
        set("profileFamilyName", c.profileFamilyName, c.hasProfileFamilyName)
        set("systemGivenName", c.systemGivenName)
        set("systemFamilyName", c.systemFamilyName)
        set("systemNickname", c.systemNickname)
        if c.hasSharedName { set("sharedGivenName", c.sharedName.given); set("sharedFamilyName", c.sharedName.family) }
        set("username", c.username, c.hasUsername)
        if c.hasNickname { set("nicknameGivenName", c.nickname.given); set("nicknameFamilyName", c.nickname.family) }
        set("note", c.note)
        if c.hasAvatarColor { attrs["color"] = Self.avatarColor(c.avatarColor) }
        if let serviceId, c.hasIdentityKey, !c.identityKey.isEmpty {
            let verified = c.identityState == .verified ? 1 : (c.identityState == .unverified ? 2 : 0)
            try ProtocolStore.save(db, .init(id: serviceId, publicKey: c.identityKey.base64EncodedString(), firstUse: true, timestamp: now,
                                             verified: verified, nonblockingApproval: true))
            attrs["verified"] = verified
        }
        if case .notRegistered(let n) = c.registration {
            let at = Self.ms(n.unregisteredTimestamp)
            attrs["discoveredUnregisteredAt"] = at ?? now
            if let at { attrs["firstUnregisteredAt"] = at }
        }
        if c.blocked {
            let at = Self.ms(c.blockedAtTimestamp)
            if let serviceId { try BlockedList.serviceIds.set(db, serviceId, blocked: true, at: at) }
            if let e164 { try BlockedList.numbers.set(db, e164, blocked: true, at: at) }
        }
        return (id, attrs)
    }

    mutating func fromGroup(_ g: BackupProto_Group) throws -> (String, [String: Any]) {
        try Self.check(g.masterKey.count == 32 && g.hasSnapshot, "group without master key or snapshot")
        let params = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: GroupMasterKey(contents: g.masterKey))
        let groupId = try params.getPublicParams().getGroupIdentifier().serialize().base64EncodedString()
        let id = try existingConversation(serviceId: nil, e164: nil, groupId: groupId) ?? UUID().uuidString.lowercased()
        let s = g.snapshot
        var attrs = conversations[id] ?? [:]
        attrs.merge(["id": id, "type": "group", "version": 2, "groupVersion": 2, "masterKey": g.masterKey.base64EncodedString(), "groupId": groupId,
                     "secretParams": params.serialize().base64EncodedString(),
                     "publicParams": try params.getPublicParams().serialize().base64EncodedString(),
                     "profileSharing": g.whitelisted, "hideStory": g.hideStory, "expireTimerVersion": 1, "unreadCount": 0,
                     "messageCount": 0, "sentMessageCount": 0, "revision": Int(s.version), "announcementsOnly": s.announcementsOnly]) { _, new in new }
        if g.whitelisted { attrs["messageRequestResponseType"] = 1 }   // ACCEPT
        switch g.storySendMode {
        case .enabled: attrs["storySendMode"] = "Always"
        case .disabled: attrs["storySendMode"] = "Never"
        default: break
        }
        if !s.avatarURL.isEmpty { attrs["avatar"] = ["url": s.avatarURL]; attrs["remoteAvatarUrl"] = s.avatarURL }
        if g.hasAvatarColor { attrs["color"] = Self.avatarColor(g.avatarColor) }
        if case .title(let t) = s.title.content { attrs["name"] = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        if case .descriptionText(let d) = s.description_p.content { attrs["description"] = d.trimmingCharacters(in: .whitespacesAndNewlines) }
        if case .disappearingMessagesDuration(let t) = s.disappearingMessagesTimer.content, t > 0 { attrs["expireTimer"] = Int(t) }
        if s.hasAccessControl {
            attrs["accessControl"] = ["attributes": s.accessControl.attributes.rawValue, "members": s.accessControl.members.rawValue,
                                      "addFromInviteLink": s.accessControl.addFromInviteLink.rawValue]
        }
        attrs["membersV2"] = s.members.compactMap { m -> [String: Any]? in
            guard let aci = Self.aci(m.userID) else { return nil }
            return ["aci": aci, "joinedAtVersion": Int(m.joinedAtVersion), "role": m.role.rawValue]
        }
        attrs["pendingMembersV2"] = s.membersPendingProfileKey.compactMap { p -> [String: Any]? in
            guard let sid = Self.serviceId(p.member.userID) else { return nil }
            return ["serviceId": sid, "role": p.member.role.rawValue, "addedByUserId": Self.aci(p.addedByUserID) ?? "", "timestamp": Self.ms(p.timestamp) ?? 0]
        }
        attrs["pendingAdminApprovalV2"] = s.membersPendingAdminApproval.compactMap { p -> [String: Any]? in
            guard let aci = Self.aci(p.userID) else { return nil }
            return ["aci": aci, "timestamp": Self.ms(p.timestamp) ?? 0]
        }
        attrs["bannedMembersV2"] = s.membersBanned.compactMap { b -> [String: Any]? in
            guard let sid = Self.serviceId(b.userID) else { return nil }
            return ["serviceId": sid, "timestamp": Self.ms(b.timestamp) ?? 0]
        }
        if !s.inviteLinkPassword.isEmpty { attrs["groupInviteLinkPassword"] = s.inviteLinkPassword.base64EncodedString() }
        if s.terminated { attrs["terminated"] = true }
        if g.blocked { try BlockedList.groups.set(db, groupId, blocked: true, at: Self.ms(g.blockedAtTimestamp)) }
        return (id, attrs)
    }

    mutating func fromDistributionList(_ item: BackupProto_DistributionListItem) throws {
        let uuid = UUID(data: item.distributionID)?.uuidString.lowercased()
        let listId = (uuid == nil || uuid == "00000000-0000-0000-0000-000000000000") ? StorageLocal.myStoryId : uuid!
        switch item.item {
        case .deletionTimestamp(let at):
            try db.execute(sql: """
                INSERT INTO storyDistributions (id, name, deletedAtTimestamp, allowsReplies, isBlockList, storageNeedsSync) VALUES (?, '', ?, 1, 0, 0)
                ON CONFLICT(id) DO UPDATE SET deletedAtTimestamp = excluded.deletedAtTimestamp
                """, arguments: [listId, Self.ms(at)])
        case .distributionList(let d):
            let isBlockList = d.privacyMode == .allExcept || d.privacyMode == .all
            try db.execute(sql: """
                INSERT INTO storyDistributions (id, name, allowsReplies, isBlockList, storageNeedsSync) VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, allowsReplies = excluded.allowsReplies, isBlockList = excluded.isBlockList
                """, arguments: [listId, listId == StorageLocal.myStoryId ? "" : d.name, d.allowReplies ? 1 : 0, isBlockList ? 1 : 0])
            try db.execute(sql: "DELETE FROM storyDistributionMembers WHERE listId = ?", arguments: [listId])
            let members = d.privacyMode == .all ? [] : d.memberRecipientIds.compactMap { recipients[$0]?.serviceId }
            for m in Set(members) {
                try db.execute(sql: "INSERT INTO storyDistributionMembers (listId, serviceId) VALUES (?, ?)", arguments: [listId, m])
            }
        case nil:
            throw Failure(description: "distribution list without item")
        }
    }

    // MARK: chats

    mutating func fromChat(_ c: BackupProto_Chat) throws {
        if c.recipientID == releaseNotesRecipient {
            try Self.check(releaseNotesChat == nil, "duplicate release notes chat")
            releaseNotesChat = c.id
            return
        }
        guard let r = recipients[c.recipientID] else { throw Failure(description: "chat of unknown recipient") }
        chats[c.id] = r.conversationId
        var attrs = conversations[r.conversationId] ?? [:]
        attrs["isArchived"] = c.archived
        attrs["isPinned"] = c.hasPinnedOrder && c.pinnedOrder != 0
        if c.hasExpirationTimerMs, c.expirationTimerMs > 0 { attrs["expireTimer"] = Int(c.expirationTimerMs / 1000) } else { attrs["expireTimer"] = nil }
        attrs["expireTimerVersion"] = max(1, Int(c.expireTimerVersion))
        if c.hasMuteUntilMs, c.muteUntilMs > 0 {
            attrs["muteExpiresAt"] = c.muteUntilMs >= UInt64(Int64.max) ? Int64.max : Int64(c.muteUntilMs)
        }
        attrs["markedUnread"] = c.markedUnread
        if c.hasNotifyForCallsIfMuted { attrs["notifyForCallsIfMuted"] = c.notifyForCallsIfMuted }
        if c.hasNotifyForMentionsIfMuted { attrs["notifyForMentionsIfMuted"] = c.notifyForMentionsIfMuted }
        else if c.dontNotifyForMentionsIfMuted { attrs["notifyForMentionsIfMuted"] = false }
        if c.hasNotifyForRepliesIfMuted { attrs["notifyForRepliesIfMuted"] = c.notifyForRepliesIfMuted }
        if c.hasShowUnreadReminders { attrs["showUnreadReminders"] = c.showUnreadReminders }
        conversations[r.conversationId] = attrs
        if c.hasPinnedOrder, c.pinnedOrder != 0 { pinned.append((c.pinnedOrder, r.conversationId)) }
    }

    // MARK: chat items

    struct Built {
        var json: [String: Any]
        var attachments: [(MessageAttachments.Location, MessageAttachment)] = []
        var reactions: [[String: Any]] = []
        /// Group changes with a timer change also become a timer notification (additional).
        var additional: [[String: Any]] = []
    }

    mutating func fromChatItem(_ item: BackupProto_ChatItem) throws {
        if item.chatID == releaseNotesChat { return }
        guard let conversationId = chats[item.chatID] else { throw Failure(description: "item of unknown chat") }
        guard let timestamp = Self.ms(item.dateSent) else { throw Failure(description: "item without dateSent") }
        let author = recipients[item.authorID]
        let expireTimer = item.hasExpiresInMs && item.expiresInMs > 0 ? Int(item.expiresInMs / 1000) : nil
        let expireStart = item.hasExpireStartDate ? Self.ms(item.expireStartDate) : nil
        if let expireTimer, let expireStart, expireStart + Int64(expireTimer) * 1000 < now { return }   // expired
        var conv = conversations[conversationId] ?? [:]
        var json: [String: Any] = ["conversationId": conversationId, "sent_at": timestamp, "timestamp": timestamp, "schemaVersion": 14,
                                   "attachments": [] as [Any]]
        if let s = author?.serviceId { json["sourceServiceId"] = s }
        if let e = author?.e164 { json["source"] = e }
        if let expireTimer { json["expireTimer"] = expireTimer }
        if let expireStart { json["expirationStartTimestamp"] = expireStart }
        if item.sms { json["sms"] = true }
        var activeAt: Int64?
        switch item.directionalDetails {
        case .outgoing(let o):
            try Self.check(author?.conversationId == ourId, "outgoing item not by us")
            json["type"] = "outgoing"
            var states: [String: [String: Any]] = [:]
            var unidentified: [String] = []
            for s in o.sendStatus {
                guard let target = recipients[s.recipientID] else { continue }
                var state: [String: Any] = [:]
                let sealed: Bool
                switch s.deliveryStatus {
                case .pending: state["status"] = "Pending"; sealed = false
                case .sent(let x): state["status"] = "Sent"; sealed = x.sealedSender
                case .delivered(let x): state["status"] = "Delivered"; sealed = x.sealedSender
                case .read(let x): state["status"] = "Read"; sealed = x.sealedSender
                case .viewed(let x): state["status"] = "Viewed"; sealed = x.sealedSender
                case .skipped: state["status"] = "Skipped"; sealed = false
                case .failed: state["status"] = "Failed"; sealed = false
                case nil: state["status"] = "Pending"; sealed = false
                }
                if let at = Self.ms(s.timestamp) { state["updatedAt"] = at }
                states[target.conversationId] = state
                if sealed, let sid = target.serviceId { unidentified.append(sid) }
            }
            if o.sendStatus.isEmpty { states[conversationId] = ["status": "Sent", "updatedAt": timestamp] }
            json["sendStateByConversationId"] = states
            if !unidentified.isEmpty { json["unidentifiedDeliveries"] = unidentified }
            json["received_at_ms"] = Self.ms(o.dateReceived) ?? timestamp
            json["readStatus"] = ReadStatus.read.rawValue
            json["seenStatus"] = SeenStatus.notApplicable.rawValue
            activeAt = timestamp
        case .incoming(let i):
            try Self.check(author != nil && author?.conversationId != ourId, "incoming item by us")
            json["type"] = "incoming"
            let received = Self.ms(i.dateReceived) ?? now
            json["received_at_ms"] = received
            if let at = Self.ms(i.dateServerSent) { json["serverTimestamp"] = at }
            json["unidentifiedDeliveryReceived"] = i.sealedSender
            json["readStatus"] = (i.read ? ReadStatus.read : .unread).rawValue
            json["seenStatus"] = (i.read ? SeenStatus.seen : .unseen).rawValue
            if !i.read { conv["unreadCount"] = ((conv["unreadCount"] as? NSNumber)?.intValue ?? 0) + 1 }
            activeAt = received
        case .directionless:
            json["type"] = "incoming"
            json["readStatus"] = ReadStatus.read.rawValue
            json["seenStatus"] = SeenStatus.seen.rawValue
            activeAt = timestamp
        case nil:
            throw Failure(description: "item without direction")
        }
        var built = Built(json: json)
        switch item.item {
        case .standardMessage(let m): try fromStandard(m, &built)
        case .contactMessage(let m):
            built.json["contact"] = [contactCard(m.contact)]
            built.reactions = reactions(m.reactions)
        case .stickerMessage(let m):
            let s = m.sticker
            built.json["sticker"] = ["packId": s.packID.hexString, "packKey": s.packKey.base64EncodedString(), "stickerId": Int(s.stickerID),
                                     "emoji": s.hasEmoji ? s.emoji : ""]
            if s.hasData { built.attachments.append((MessageAttachments.Location(messageId: "", type: .sticker, order: 0), attachment(s.data))) }
            built.reactions = reactions(m.reactions)
        case .remoteDeletedMessage:
            built.json["deletedForEveryone"] = true
        case .adminDeletedMessage:
            built.json["deletedForEveryone"] = true
        case .viewOnceMessage(let m):
            built.json["isViewOnce"] = true
            if m.hasAttachment {
                built.attachments.append((MessageAttachments.Location(messageId: "", type: .attachment, order: 0), attachment(m.attachment)))
            } else {
                built.json["isErased"] = true   // already viewed
            }
            built.reactions = reactions(m.reactions)
        case .directStoryReplyMessage(let m):
            if case .textReply(let t) = m.reply {
                built.json["body"] = t.text.body
                if !t.text.bodyRanges.isEmpty { built.json["bodyRanges"] = bodyRanges(t.text.bodyRanges) }
            } else if case .emoji(let e) = m.reply {
                built.json["storyReaction"] = ["emoji": e, "targetAuthorAci": account.aci, "targetTimestamp": 0]
            }
            built.reactions = reactions(m.reactions)
        case .poll(let p):
            var votes: [String: [String: Any]] = [:]
            for (index, option) in p.options.enumerated() {
                for v in option.votes {
                    guard let voter = recipients[v.voterID] else { continue }
                    var record = votes[voter.conversationId] ?? ["fromConversationId": voter.conversationId, "optionIndexes": [Int](),
                                                                   "voteCount": Int(max(1, v.voteCount)), "timestamp": timestamp]
                    record["optionIndexes"] = (record["optionIndexes"] as? [Int] ?? []) + [index]
                    votes[voter.conversationId] = record
                }
            }
            var poll: [String: Any] = ["question": p.question, "options": p.options.map(\.option), "allowMultiple": p.allowMultiple]
            if !votes.isEmpty { poll["votes"] = Array(votes.values) }
            if p.hasEnded_p { poll["terminatedAt"] = timestamp }
            built.json["poll"] = poll
            built.reactions = reactions(p.reactions)
        case .updateMessage(let u):
            guard try fromUpdate(u, item: item, author: author, conversation: conv, conversationId: conversationId, &built) else { return }
            if !Self.affectsChatList(u) { activeAt = nil }
        case .paymentNotification, .giftBadge:
            return    // no payments or donations
        case nil:
            throw Failure(description: "item without content")
        }
        if !item.revisions.isEmpty {
            built.json["editHistory"] = try item.revisions.map { rev -> [String: Any] in
                var b = Built(json: [:])
                if case .standardMessage(let m) = rev.item { try fromStandard(m, &b) }
                var entry: [String: Any] = ["timestamp": Self.ms(rev.dateSent) ?? timestamp, "body": b.json["body"] ?? "",
                                            "attachments": [] as [Any], "received_at": now, "received_at_ms": now]
                if let ranges = b.json["bodyRanges"] { entry["bodyRanges"] = ranges }
                return entry
            } + [["timestamp": timestamp, "body": built.json["body"] ?? "", "attachments": [] as [Any], "received_at": now, "received_at_ms": now]]
            built.json["editMessageTimestamp"] = timestamp
            if let oldest = item.revisions.first.flatMap({ Self.ms($0.dateSent) }) {
                built.json["timestamp"] = oldest
                built.json["sent_at"] = oldest
            }
        }
        let messageId = try insert(built.json, attachments: built.attachments, reactions: built.reactions, conversationId: conversationId)
        var sentAt = (built.json["sent_at"] as? Int64) ?? timestamp
        for extra in built.additional {
            sentAt -= 1
            var j = built.json
            j.merge(extra) { _, new in new }
            j["sent_at"] = sentAt
            _ = try insert(j, attachments: [], reactions: [], conversationId: conversationId)
        }
        if case .outgoing = item.directionalDetails {
            conv["sentMessageCount"] = ((conv["sentMessageCount"] as? NSNumber)?.intValue ?? 0) + 1
        } else if case .incoming = item.directionalDetails {
            conv["messageCount"] = ((conv["messageCount"] as? NSNumber)?.intValue ?? 0) + 1
        }
        if let activeAt { conv["active_at"] = max((conv["active_at"] as? NSNumber)?.int64Value ?? 0, activeAt) }
        if item.hasPinDetails, let at = Self.ms(item.pinDetails.pinnedAtTimestamp) {
            let expires: Int64? = { if case .pinExpiresAtTimestamp(let e) = item.pinDetails.pinExpiry { return Self.ms(e) } else { return nil } }()
            try db.execute(sql: "INSERT OR IGNORE INTO pinnedMessages (conversationId, messageId, pinnedAt, expiresAt) VALUES (?, ?, ?, ?)",
                           arguments: [conversationId, messageId, at, expires])
        }
        conversations[conversationId] = conv
    }

    /// Profile changes, learned names, session switchovers, merges and member-left-only group
    /// changes do not bring a chat into the list (`shouldChatItemAffectChatListPresence`).
    static func affectsChatList(_ u: BackupProto_ChatUpdateMessage) -> Bool {
        switch u.update {
        case .profileChange, .learnedProfileChange, .sessionSwitchover, .threadMerge: return false
        case .groupChange(let g):
            return !g.updates.allSatisfy {
                if case .groupMemberLeftUpdate = $0.update { return true }
                if case .groupV2MigrationUpdate = $0.update { return true }
                return false
            }
        case .simpleUpdate(let s):
            return ![.identityUpdate, .identityVerified, .identityDefault, .changeNumber, .endSession, .chatSessionRefresh].contains(s.type)
        default: return true
        }
    }

    func bodyRanges(_ ranges: [BackupProto_BodyRange]) -> [[String: Any]] {
        ranges.compactMap { r -> [String: Any]? in
            switch r.associatedValue {
            case .mentionAci(let a): return Self.aci(a).map { ["start": Int(r.start), "length": Int(r.length), "mentionAci": $0] }
            case .style(let s): return ["start": Int(r.start), "length": Int(r.length), "style": s.rawValue]
            case nil: return nil
            }
        }
    }

    func reactions(_ rs: [BackupProto_Reaction]) -> [[String: Any]] {
        rs.sorted { $0.sortOrder < $1.sortOrder }.compactMap { r -> [String: Any]? in
            guard let from = recipients[r.authorID], let at = Self.ms(r.sentTimestamp) else { return nil }
            return ["emoji": r.emoji, "fromId": from.conversationId, "targetTimestamp": at, "timestamp": at]
        }
    }

    /// convertFilePointerToAttachment: transit-tier locators download from the CDN.
    func attachment(_ p: BackupProto_FilePointer) -> MessageAttachment {
        let l = p.locatorInfo
        var a = MessageAttachment(contentType: p.hasContentType && !p.contentType.isEmpty ? p.contentType : "application/octet-stream", size: Int(l.size))
        if !l.key.isEmpty { a.key = l.key.base64EncodedString() }
        if !l.plaintextHash.isEmpty { a.plaintextHash = l.plaintextHash.hexString }
        if !l.encryptedDigest.isEmpty { a.digest = l.encryptedDigest.base64EncodedString() }
        if !l.transitCdnKey.isEmpty {
            a.cdnKey = l.transitCdnKey
            a.cdnNumber = Int(l.transitCdnNumber)
            if l.transitTierUploadTimestamp > 0 { a.uploadTimestamp = l.transitTierUploadTimestamp }
        }
        if p.hasFileName { a.fileName = p.fileName }
        if p.hasWidth { a.width = Int(p.width) }
        if p.hasHeight { a.height = Int(p.height) }
        if p.hasCaption { a.caption = p.caption }
        if p.hasBlurHash { a.blurHash = p.blurHash }
        if p.hasIncrementalMac, !p.incrementalMac.isEmpty, p.hasIncrementalMacChunkSize {
            a.incrementalMac = p.incrementalMac.base64EncodedString()
            a.chunkSize = Int(p.incrementalMacChunkSize)
        }
        if p.hasAudioDurationSeconds { a.duration = Double(p.audioDurationSeconds) }
        return a
    }

    func attachment(_ m: BackupProto_MessageAttachment) -> MessageAttachment {
        var a = attachment(m.pointer)
        switch m.flag {
        case .voiceMessage: a.flags = 1
        case .borderless: a.flags = 2
        case .gif: a.flags = 8
        default: break
        }
        if m.hasClientUuid { a.clientUuid = UUID(data: m.clientUuid)?.uuidString.lowercased() }
        return a
    }

    mutating func fromStandard(_ m: BackupProto_StandardMessage, _ b: inout Built) throws {
        if m.hasText {
            b.json["body"] = m.hasLongText ? m.text.body : m.text.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.text.bodyRanges.isEmpty { b.json["bodyRanges"] = bodyRanges(m.text.bodyRanges) }
        }
        if m.hasLongText { b.attachments.append((MessageAttachments.Location(messageId: "", type: .longMessage, order: 0), attachment(m.longText))) }
        for (i, a) in m.attachments.enumerated() {
            b.attachments.append((MessageAttachments.Location(messageId: "", type: .attachment, order: i), attachment(a)))
        }
        if !m.linkPreview.isEmpty {
            b.json["preview"] = m.linkPreview.enumerated().map { i, p -> [String: Any] in
                var d: [String: Any] = ["url": p.url]
                if p.hasTitle { d["title"] = p.title }
                if p.hasDescription_p { d["description"] = p.description_p }
                if p.hasDate, let at = Self.ms(p.date) { d["date"] = at }
                if p.hasImage { b.attachments.append((MessageAttachments.Location(messageId: "", type: .preview, order: i), attachment(p.image))) }
                return d
            }
        }
        if m.hasQuote, let author = recipients[m.quote.authorID] {
            let q = m.quote
            var quote: [String: Any] = ["referencedMessageNotFound": !q.hasTargetSentTimestamp,
                                        "isViewOnce": q.type == .viewOnce, "isGiftBadge": q.type == .giftBadge,
                                        "attachments": q.attachments.map { qa -> [String: Any] in
                                            ["contentType": qa.hasContentType ? qa.contentType : "application/octet-stream",
                                             "fileName": qa.hasFileName ? qa.fileName : NSNull()]
                                        }]
            quote["id"] = q.hasTargetSentTimestamp ? (Self.ms(q.targetSentTimestamp) as Any) : NSNull()
            if author.conversationId == ourId { quote["authorAci"] = account.aci }
            else if let s = author.serviceId, !s.hasPrefix("PNI:") { quote["authorAci"] = s } else if let e = author.e164 { quote["author"] = e }
            if q.hasText {
                quote["text"] = q.text.body
                if !q.text.bodyRanges.isEmpty { quote["bodyRanges"] = bodyRanges(q.text.bodyRanges) }
            }
            if q.type == .poll { quote["isPoll"] = true }
            b.json["quote"] = quote
        }
        b.reactions = reactions(m.reactions)
    }

    func contactCard(_ c: BackupProto_ContactAttachment) -> [String: Any] {
        var out: [String: Any] = [:]
        var name: [String: Any] = [:]
        for (k, v) in [("givenName", c.name.givenName), ("familyName", c.name.familyName), ("prefix", c.name.prefix), ("suffix", c.name.suffix),
                       ("middleName", c.name.middleName), ("nickname", c.name.nickname)] where !v.isEmpty { name[k] = v }
        if !name.isEmpty { out["name"] = name }
        if !c.number.isEmpty { out["number"] = c.number.map { ["value": $0.value, "type": $0.type.rawValue, "label": $0.label] } }
        if !c.email.isEmpty { out["email"] = c.email.map { ["value": $0.value, "type": $0.type.rawValue, "label": $0.label] } }
        if !c.organization.isEmpty { out["organization"] = c.organization }
        return out
    }

    // MARK: updates

    /// Returns false for an update not to import.
    mutating func fromUpdate(_ u: BackupProto_ChatUpdateMessage, item: BackupProto_ChatItem, author: Recipient?, conversation: [String: Any],
                             conversationId: String, _ b: inout Built) throws -> Bool {
        let source = author?.serviceId ?? account.aci
        switch u.update {
        case .expirationTimerChange(let t):
            b.json["type"] = "timer-notification"
            b.json["sourceServiceId"] = source
            b.json["flags"] = 2       // EXPIRATION_TIMER_UPDATE
            b.json["expirationTimerUpdate"] = ["expireTimer": Int(t.expiresInMs / 1000), "sourceServiceId": source]
        case .simpleUpdate(let s):
            switch s.type {
            case .endSession: b.json["flags"] = 1
            case .chatSessionRefresh: b.json["type"] = "chat-session-refreshed"
            case .identityUpdate:
                b.json["type"] = "keychange"
                if conversation["type"] as? String == "group", let a = author?.serviceId { b.json["key_changed"] = a }
            case .identityVerified, .identityDefault:
                guard let author else { throw Failure(description: "verification change without author") }
                b.json["type"] = "verified-change"
                b.json["verifiedChanged"] = author.conversationId
                b.json["verified"] = s.type == .identityVerified
            case .changeNumber: b.json["type"] = "change-number-notification"
            case .joinedSignal: b.json["type"] = "joined-signal-notification"
            case .badDecrypt: b.json["type"] = "delivery-issue"
            case .unsupportedProtocolMessage:
                b.json["supportedVersionAtReceive"] = 5
                b.json["requiredProtocolVersion"] = 6
            case .reportedSpam, .blocked, .unblocked, .messageRequestAccepted:
                b.json["type"] = "message-request-response-event"
                b.json["messageRequestResponseEvent"] = [.reportedSpam: "SPAM", .blocked: "BLOCK", .unblocked: "UNBLOCK",
                                                         .messageRequestAccepted: "ACCEPT"][s.type]
            case .releaseChannelDonationRequest, .paymentsActivated, .paymentActivationRequest:
                return false     // no donations or payments
            default:
                throw Failure(description: "unsupported simple update \(s.type)")
            }
        case .profileChange(let p):
            b.json["type"] = "profile-change"
            if let a = author { b.json["changedId"] = a.conversationId }
            b.json["profileChange"] = ["type": "name", "oldName": p.previousName, "newName": p.newName]
        case .learnedProfileChange(let l):
            var info: [String: Any] = ["type": "private"]
            switch l.previousName {
            case .e164(let e) where e != 0: info["e164"] = "+\(e)"
            case .username(let n): info["username"] = n
            case .sharedName(let n): info["sharedGivenName"] = n
            default: result.frameErrors += 1
            }
            b.json["type"] = "title-transition-notification"
            b.json["titleTransition"] = ["renderInfo": info]
        case .threadMerge(let m):
            b.json["type"] = "conversation-merge"
            b.json["conversationMerge"] = ["renderInfo": ["type": "private", "e164": "+\(m.previousE164)"]]
        case .sessionSwitchover(let s):
            b.json["type"] = "phone-number-discovery"
            b.json["phoneNumberDiscovery"] = ["e164": "+\(s.e164)"]
        case .individualCall(let c):
            guard let peer = conversation["serviceId"] as? String ?? conversation["e164"] as? String, let started = Self.ms(c.startedCallTimestamp) else {
                throw Failure(description: "individual call without peer or start")
            }
            let callId = c.hasCallID && c.callID != 0 ? String(c.callID) : UUID().uuidString.lowercased()
            let outgoing = c.direction == .outgoing
            let status: CallStatus
            switch c.state {
            case .accepted: status = .accepted
            case .notAccepted: status = .declined
            case .missed: status = .missed
            case .missedNotificationProfile: status = .missedNotificationProfile
            default: status = .unknown
            }
            try CallHistoryStore.save(db, CallHistoryDetails(details: CallDetails(callId: callId, peerId: peer, ringerId: outgoing ? account.aci : peer,
                                                                             startedById: nil, mode: .direct, type: c.type == .videoCall ? .video : .audio,
                                                                             direction: outgoing ? .outgoing : .incoming, timestamp: started,
                                                                             endedTimestamp: nil),
                                                        status: status))
            b.json["type"] = "call-history"
            b.json["callId"] = callId
            b.json["sourceServiceId"] = nil
            b.json["source"] = nil
            b.json["readStatus"] = ReadStatus.read.rawValue
            b.json["seenStatus"] = (c.read ? SeenStatus.seen : .unseen).rawValue
        case .groupCall(let c):
            guard let groupId = conversation["groupId"] as? String, let started = Self.ms(c.startedCallTimestamp) else {
                throw Failure(description: "group call outside a group")
            }
            let callId = c.hasCallID && c.callID != 0 ? String(c.callID) : UUID().uuidString.lowercased()
            let ringer = c.hasRingerRecipientID ? recipients[c.ringerRecipientID]?.serviceId : nil
            let startedBy = c.hasStartedCallRecipientID ? recipients[c.startedCallRecipientID]?.serviceId : nil
            let status: CallStatus
            switch c.state {
            case .joined, .accepted: status = .joined
            case .ringing: status = .ringing
            case .declined: status = .declined
            case .missed: status = .missed
            case .missedNotificationProfile: status = .missedNotificationProfile
            case .outgoingRing: status = .outgoingRing
            default: status = .genericGroupCall
            }
            try CallHistoryStore.save(db, CallHistoryDetails(details: CallDetails(callId: callId, peerId: groupId, ringerId: ringer, startedById: startedBy,
                                                                             mode: .group, type: .group,
                                                                             direction: ringer == account.aci ? .outgoing : .incoming, timestamp: started,
                                                                             endedTimestamp: c.hasEndedCallTimestamp ? Self.ms(c.endedCallTimestamp) : nil),
                                                        status: status))
            b.json["type"] = "call-history"
            b.json["callId"] = callId
            b.json["sourceServiceId"] = nil
            b.json["source"] = nil
            b.json["readStatus"] = ReadStatus.read.rawValue
            b.json["seenStatus"] = (c.read ? SeenStatus.seen : .unseen).rawValue
        case .groupChange(let g):
            try fromGroupChange(g, &b)
        case .pinMessage(let p):
            guard let target = recipients[p.authorID], let aci = target.conversationId == ourId ? account.aci : target.serviceId else {
                throw Failure(description: "pin of unknown author")
            }
            b.json["type"] = "pinned-message-notification"
            b.json["pinMessage"] = ["targetAuthorAci": aci, "targetSentTimestamp": Self.ms(p.targetSentTimestamp) ?? 0]
        case .pollTerminate(let p):
            b.json["type"] = "poll-terminate"
            b.json["pollTerminateNotification"] = ["question": p.question, "pollTimestamp": Self.ms(p.targetSentTimestamp) ?? 0]
        case nil:
            throw Failure(description: "update without content")
        }
        return true
    }

    /// #fromGroupUpdateMessage: one group-v2-change with a detail per update (`summary` for
    /// those this port does not name), a timer change as its own timer notification.
    mutating func fromGroupChange(_ g: BackupProto_GroupChangeChatUpdate, _ b: inout Built) throws {
        var details: [[String: Any]] = []
        var from: String?
        func by(_ d: Data) { if let a = Self.aci(d) { from = a } }
        for u in g.updates {
            switch u.update {
            case .genericGroupUpdate(let x): by(x.updaterAci); details.append(["type": "summary"])
            case .groupCreationUpdate(let x): by(x.updaterAci); details.append(["type": "create"])
            case .groupNameUpdate(let x): by(x.updaterAci); details.append(["type": "title", "newTitle": x.hasNewGroupName ? x.newGroupName : NSNull()])
            case .groupAvatarUpdate(let x): by(x.updaterAci); details.append(["type": "avatar", "removed": x.wasRemoved])
            case .groupDescriptionUpdate(let x):
                by(x.updaterAci)
                var d: [String: Any] = ["type": "description"]
                if x.hasNewDescription, !x.newDescription.isEmpty { d["description"] = x.newDescription } else { d["removed"] = true }
                details.append(d)
            case .groupMembershipAccessLevelChangeUpdate(let x):
                by(x.updaterAci); details.append(["type": "access-members", "newPrivilege": x.accessLevel.rawValue])
            case .groupAttributesAccessLevelChangeUpdate(let x):
                by(x.updaterAci); details.append(["type": "access-attributes", "newPrivilege": x.accessLevel.rawValue])
            case .groupAnnouncementOnlyChangeUpdate(let x):
                by(x.updaterAci); details.append(["type": "announcements-only", "announcementsOnly": x.isAnnouncementOnly])
            case .groupAdminStatusUpdate(let x):
                by(x.updaterAci)
                guard let member = Self.aci(x.memberAci) else { throw Failure(description: "admin change without member") }
                details.append(["type": "member-privilege", "aci": member, "newPrivilege": x.wasAdminStatusGranted ? 2 : 1])
            case .groupMemberLeftUpdate(let x):
                guard let a = Self.aci(x.aci) else { throw Failure(description: "member left without aci") }
                from = a
                details.append(["type": "member-remove", "aci": a])
            case .groupMemberRemovedUpdate(let x):
                by(x.removerAci)
                guard let a = Self.aci(x.removedAci) else { throw Failure(description: "member removed without aci") }
                details.append(["type": "member-remove", "aci": a])
            case .groupMemberJoinedUpdate(let x):
                guard let a = Self.aci(x.newMemberAci) else { throw Failure(description: "member joined without aci") }
                from = a
                details.append(["type": "member-add", "aci": a])
            case .groupMemberAddedUpdate(let x):
                by(x.updaterAci)
                guard let a = Self.aci(x.newMemberAci) else { throw Failure(description: "member added without aci") }
                details.append(["type": "member-add", "aci": a])
            case .groupInvitationAcceptedUpdate(let x):
                guard let a = Self.aci(x.newMemberAci) else { throw Failure(description: "invitation accepted without aci") }
                from = a
                details.append(["type": "member-add-from-invite", "aci": a, "inviter": Self.aci(x.inviterAci) ?? NSNull()])
            case .groupExpirationTimerUpdate(let x):
                by(x.updaterAci)
                b.additional.append(["type": "timer-notification", "flags": 2, "sourceServiceId": from ?? account.aci,
                                     "expirationTimerUpdate": ["expireTimer": Int(x.expiresInMs / 1000), "sourceServiceId": from ?? account.aci]])
            default:
                details.append(["type": "summary"])
            }
        }
        if details.isEmpty, !b.additional.isEmpty {
            b.json.merge(b.additional.removeFirst()) { _, new in new }
            return
        }
        b.json["type"] = "group-v2-change"
        b.json["sourceServiceId"] = from
        b.json["groupV2Change"] = ["from": (from as Any?) ?? NSNull(), "details": details]
    }

    // MARK: other frames

    mutating func fromStickerPack(_ p: BackupProto_StickerPack) throws {
        try Self.check(p.packID.count == 16 && p.packKey.count == 32, "sticker pack ids")
        let id = p.packID.hexString, key = p.packKey.base64EncodedString()
        let position = try Int64.fetchOne(db, sql: "SELECT ifnull(max(position), 0) + 1 FROM sticker_packs") ?? 1
        try db.execute(sql: """
            INSERT INTO sticker_packs (id, key, status, attemptedStatus, position, createdAt, downloadAttempts) VALUES (?, ?, 'pending', 'installed', ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET key = excluded.key, attemptedStatus = 'installed'
            """, arguments: [id, key, position, now])
        try JobQueue.insert(db, queueType: StickerPackDownloadJob.queueType,
                            payload: StickerPackDownloadJob(packId: id, packKey: key, finalStatus: "installed", position: Int(position), actionSource: "backup"))
    }

    mutating func fromChatFolder(_ f: BackupProto_ChatFolder) throws {
        let id = UUID(data: f.id)?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
        let folder = ChatFolder(id: id, folderType: f.folderType == .all ? .all : .custom, name: f.name, position: folderPosition,
                                showOnlyUnread: f.showOnlyUnread, showMutedChats: f.showMutedChats, includeAllIndividualChats: f.includeAllIndividualChats,
                                includeAllGroupChats: f.includeAllGroupChats,
                                includedConversationIds: f.includedRecipientIds.compactMap { recipients[$0]?.conversationId },
                                excludedConversationIds: f.excludedRecipientIds.compactMap { recipients[$0]?.conversationId })
        folderPosition += 1
        if folder.folderType == .all { try db.execute(sql: "DELETE FROM chatFolders WHERE folderType = 1") }
        try ChatFolderStore.insert(db, folder)
    }

    mutating func fromNotificationProfile(_ p: BackupProto_NotificationProfile) throws {
        try Self.check(p.id.count == 16, "notification profile id")
        let allowed = try MessageStore.jsonString(p.allowedMembers.compactMap { recipients[$0]?.conversationId })
        var days: [String: Bool] = [:]
        for d in 1...7 { days[String(d)] = p.scheduleDaysEnabled.contains { $0.rawValue == d } }
        try db.execute(sql: """
            INSERT INTO notificationProfiles (id, name, emoji, color, createdAtMs, allowAllCalls, allowAllMentions, allowedMembersJson, scheduleEnabled,
              scheduleStartTime, scheduleEndTime, scheduleDaysEnabledJson, storageNeedsSync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO NOTHING
            """, arguments: [p.id.hexString, p.name, p.hasEmoji ? p.emoji : nil, Int64(p.color), Int64(p.createdAtMs), p.allowAllCalls ? 1 : 0,
                             p.allowAllMentions ? 1 : 0, allowed, p.scheduleEnabled ? 1 : 0, Int(p.scheduleStartTime), Int(p.scheduleEndTime),
                             try MessageStore.jsonString(days)])
    }

    // MARK: writing a message

    mutating func insert(_ json: [String: Any], attachments: [(MessageAttachments.Location, MessageAttachment)], reactions: [[String: Any]],
                         conversationId: String) throws -> String {
        let id = UUID().uuidString.lowercased()
        let receivedAt = try MessageStore.nextReceivedAt(db)
        var j = json
        j["id"] = id
        j["received_at"] = receivedAt
        if j["received_at_ms"] == nil { j["received_at_ms"] = j["sent_at"] }
        if !reactions.isEmpty {
            j["reactions"] = reactions.map { r -> [String: Any] in
                var x = r
                x["targetAuthorAci"] = j["sourceServiceId"] ?? account.aci
                return x
            }
        }
        let type = j["type"] as? String ?? "incoming"
        let sentAt = (j["sent_at"] as? Int64) ?? 0
        let expireTimer = (j["expireTimer"] as? Int)
        try db.execute(sql: """
            INSERT INTO messages (id, json, readStatus, seenStatus, sent_at, conversationId, received_at, type, body, sourceServiceId, expireTimer,
                                  expirationStartTimestamp, isViewOnce, isErased, hasAttachments, hasFileAttachments, hasVisualMediaAttachments, schemaVersion)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 14)
            """, arguments: [id, try MessageStore.jsonString(j), j["readStatus"] as? Int, j["seenStatus"] as? Int, sentAt, conversationId, receivedAt,
                             type, j["body"] as? String, j["sourceServiceId"] as? String, expireTimer, j["expirationStartTimestamp"] as? Int64,
                             (j["isViewOnce"] as? Bool ?? false) ? 1 : 0, (j["isErased"] as? Bool ?? false) ? 1 : 0])
        for (loc, a) in attachments {
            let l = MessageAttachments.Location(messageId: id, type: loc.type, order: loc.order)
            try MessageAttachments.upsert(db, l, conversationId: conversationId, sentAt: sentAt, receivedAt: receivedAt, messageType: type, a)
        }
        if !attachments.isEmpty { try MessageAttachments.updateMessageFlags(db, messageId: id) }
        for r in reactions {
            try db.execute(sql: """
                INSERT INTO reactions (conversationId, emoji, fromId, messageReceivedAt, targetAuthorAci, targetTimestamp, unread, messageId, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, arguments: [conversationId, r["emoji"] as? String, r["fromId"] as? String, receivedAt, (j["sourceServiceId"] as? String) ?? account.aci,
                                 sentAt, id, r["timestamp"] as? Int64])
        }
        result.messages += 1
        return id
    }
}
