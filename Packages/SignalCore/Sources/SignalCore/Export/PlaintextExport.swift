// "Export chat history" (services/backups exportPlaintext): the account, recipients, chats and
// their messages as Backup.proto frames, written by libsignal's BackupJsonExporter as JSON
// lines to signal-export-<time>/main.jsonl, metadata.json beside it, and — with media — each
// attachment's plaintext at files/<first two>/<plaintextHash>.
//
// Covered: account data and settings, contacts / groups / distribution lists / self / release
// notes, chats (archive, pin, mute, timer, marked unread), standard messages (text with
// mentions and styles, attachments, quotes, reactions, send states), stickers, chat folders
// and notification profiles. Disappearing messages are excluded, as upstream; stories and
// system notices (group updates, calls, safety numbers…) are not exported here.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum PlaintextExportError: Error, Equatable {
    case notEnoughStorage(bytesNeeded: Int64)
    case ranOutOfStorage(bytesNeeded: Int64)
    case storagePermissions
    case general(String)
}

public struct PlaintextExportResult: Sendable {
    public var exportDirectory: URL
    public var frameCount: Int
    public var mediaFiles: Int
}

public enum PlaintextExport {
    /// `MIMINUM_DISK_SPACE_FOR_LOCAL_EXPORT`
    public static let minimumDiskSpace: Int64 = 200 * 1024 * 1024
    static let localBackupVersion = 1

    /// `exportPlaintext`: into a new folder in `target`; on any error the folder is removed.
    public static func export(database: SignalDatabase, account: Account, attachments: AttachmentStore?, to target: URL, includeMedia: Bool,
                              appVersion: String = "SignalSafe", now: Date = Date(),
                              onProgress: @escaping @Sendable (_ current: Int64, _ total: Int64) -> Void = { _, _ in }) async throws
        -> PlaintextExportResult
    {
        let free = (try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if free < minimumDiskSpace { throw PlaintextExportError.notEnoughStorage(bytesNeeded: minimumDiskSpace - free) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dir = target.appendingPathComponent("signal-export-\(formatter.string(from: now))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let built = try await database.pool.write { db in      // ourConversation may create our row
                var builder = FrameBuilder(db: db, account: account, now: now)
                return try builder.build()
            }
            var info = BackupProto_BackupInfo()
            info.version = 1
            info.backupTimeMs = UInt64(now.timeIntervalSince1970 * 1000)
            info.mediaRootBackupKey = Data(SignalCrypto.randomBytes(32))
            info.currentAppVersion = appVersion
            info.firstAppVersion = appVersion
            let exporter = try BackupJsonExporter(backupInfo: try info.serializedBytes() as Data, validate: false)
            var out = Data((exporter.initialChunk + "\n").utf8)
            for frame in built.frames {
                let bytes: Data = try frame.serializedBytes()
                for result in try exporter.exportFrames(varint(UInt64(bytes.count)) + bytes) {
                    if let line = result.line { out.append(Data((line + "\n").utf8)) }
                }
            }
            try? exporter.finishExport()
            try out.write(to: dir.appendingPathComponent("main.jsonl"))
            try Data("{\"version\":\(localBackupVersion)}".utf8).write(to: dir.appendingPathComponent("metadata.json"))
            var written = 0
            if includeMedia, let attachments {
                let total = built.media.reduce(Int64(0)) { $0 + Int64($1.size) }
                var done: Int64 = 0
                for a in built.media {
                    guard let hash = a.plaintextHash, hash.count >= 2, let data = try attachments.plaintext(of: a) else { continue }
                    let folder = dir.appendingPathComponent("files").appendingPathComponent(String(hash.prefix(2)))
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: folder.appendingPathComponent(hash))
                    written += 1
                    done += Int64(a.size)
                    onProgress(done, total)
                }
            }
            return PlaintextExportResult(exportDirectory: dir, frameCount: built.frames.count, mediaFiles: written)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
                throw PlaintextExportError.storagePermissions
            }
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { throw PlaintextExportError.ranOutOfStorage(bytesNeeded: 0) }
            if let e = error as? PlaintextExportError { throw e }
            throw PlaintextExportError.general(String(describing: error))
        }
    }

    /// Protobuf length delimiting (`encodeDelimited`).
    static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
}

/// Builds the frames from the database.
struct FrameBuilder {
    let db: Database
    let account: Account
    let now: Date
    var recipientIds: [String: UInt64] = [:]     // conversation id → recipient id
    var nextId: UInt64 = 1
    var frames: [BackupProto_Frame] = []
    var media: [MessageAttachment] = []

    init(db: Database, account: Account, now: Date) {
        self.db = db
        self.account = account
        self.now = now
    }

    static func json(_ s: String?) -> [String: Any] { (s.flatMap { try? MessageStore.jsonObject($0) }) ?? [:] }
    static func str(_ j: [String: Any], _ k: String) -> String { j[k] as? String ?? "" }
    static func bytes(_ b64: Any?) -> Data { (b64 as? String).flatMap { Data(base64Encoded: $0) } ?? Data() }
    static func aci(_ s: String?) -> Data? { s.flatMap { try? ServiceId.parseFrom(serviceIdString: $0).serviceIdBinary } }

    static func frame(_ set: (inout BackupProto_Frame) -> Void) -> BackupProto_Frame {
        var f = BackupProto_Frame()
        set(&f)
        return f
    }

    mutating func build() throws -> (frames: [BackupProto_Frame], media: [MessageAttachment]) {
        let ourId = try StorageLocal.ourConversation(db, account: account)
        let our = Self.json(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [ourId]))

        // AccountData
        let frame1 = Self.frame { f in
            var a = BackupProto_AccountData()
            if let pk = account.profileKey { a.profileKey = pk }
            a.givenName = Self.str(our, "profileName")
            a.familyName = Self.str(our, "profileFamilyName")
            a.username = Self.str(our, "username")
            var s = BackupProto_AccountData.AccountSettings()
            s.readReceipts = (try? Items.get(db, "read-receipt-setting", as: Bool.self)) ?? false
            s.typingIndicators = (try? Items.get(db, "typingIndicators", as: Bool.self)) ?? false
            s.linkPreviews = (try? Items.get(db, "linkPreviews", as: Bool.self)) ?? false
            s.storyViewReceiptsEnabled = (try? Items.get(db, "storyViewReceiptsEnabled", as: Bool.self)) ?? true
            s.universalExpireTimerSeconds = UInt32((try? Items.get(db, "universalExpireTimer", as: Int.self)) ?? 0)
            a.accountSettings = s
            f.account = a
        }
        frames.append(frame1)

        // Self, release notes.
        let selfId = nextId; nextId += 1
        recipientIds[ourId] = selfId
        let frame2 = Self.frame { f in
            var r = BackupProto_Recipient()
            r.id = selfId
            r.self_p = BackupProto_Self()
            f.recipient = r
        }
        frames.append(frame2)
        let releaseNotesId = nextId; nextId += 1
        let frame3 = Self.frame { f in
            var r = BackupProto_Recipient()
            r.id = releaseNotesId
            r.releaseNotes = BackupProto_ReleaseNotes()
            f.recipient = r
        }
        frames.append(frame3)

        // Contacts and groups.
        let conversations = try Row.fetchAll(db, sql: "SELECT id, type, serviceId, json FROM conversations WHERE id != ?", arguments: [ourId])
        for row in conversations {
            let id: String = row["id"]
            let j = Self.json(row["json"])
            let rid = nextId
            if (row["type"] as String) == "private" {
                guard let aci = Self.aci(row["serviceId"]) else { continue }
                var c = BackupProto_Contact()
                c.aci = aci
                if let e164 = (j["e164"] as? String).flatMap({ UInt64($0.filter(\.isNumber)) }) { c.e164 = e164 }
                c.username = Self.str(j, "username")
                c.profileKey = Self.bytes(j["profileKey"])
                c.profileSharing = j["profileSharing"] as? Bool ?? false
                c.profileGivenName = Self.str(j, "profileName")
                c.profileFamilyName = Self.str(j, "profileFamilyName")
                c.systemGivenName = Self.str(j, "systemGivenName")
                c.systemFamilyName = Self.str(j, "systemFamilyName")
                c.blocked = j["isBlocked"] as? Bool ?? false
                c.note = Self.str(j, "note")
                if let given = j["nicknameGivenName"] as? String {
                    var n = BackupProto_Contact.Name()
                    n.given = given
                    n.family = Self.str(j, "nicknameFamilyName")
                    c.nickname = n
                }
                c.registered = BackupProto_Contact.Registered()
                let frame4 = Self.frame { f in
                    var r = BackupProto_Recipient()
                    r.id = rid
                    r.contact = c
                    f.recipient = r
                }
                frames.append(frame4)
            } else {
                let mk = Self.bytes(j["masterKey"])
                guard mk.count == 32 else { continue }
                var g = BackupProto_Group()
                g.masterKey = mk
                g.whitelisted = j["profileSharing"] as? Bool ?? false
                g.blocked = j["isBlocked"] as? Bool ?? false
                var snap = BackupProto_Group.GroupSnapshot()
                var title = BackupProto_Group.GroupAttributeBlob()
                title.title = Self.str(j, "name")
                snap.title = title
                snap.version = UInt32((j["revision"] as? NSNumber)?.intValue ?? 0)
                g.snapshot = snap
                let frame5 = Self.frame { f in
                    var r = BackupProto_Recipient()
                    r.id = rid
                    r.group = g
                    f.recipient = r
                }
                frames.append(frame5)
            }
            recipientIds[id] = rid
            nextId += 1
        }

        // Distribution lists.
        for list in try StoryDistributionLists.all(db) {
            guard let uuid = UUID(uuidString: list.id) else { continue }
            let rid = nextId; nextId += 1
            var item = BackupProto_DistributionListItem()
            item.distributionID = uuid.data
            var d = BackupProto_DistributionList()
            d.name = list.id == StoryStore.myStoryId ? "" : list.name
            d.allowReplies = list.allowsReplies
            d.privacyMode = list.id == StoryStore.myStoryId ? (list.isBlockList ? (list.members.isEmpty ? .all : .allExcept) : .onlyWith) : .onlyWith
            d.memberRecipientIds = try list.members.compactMap { s in
                try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [s]).flatMap { recipientIds[$0] }
            }
            item.distributionList = d
            let frame6 = Self.frame { f in
                var r = BackupProto_Recipient()
                r.id = rid
                r.distributionList = item
                f.recipient = r
            }
            frames.append(frame6)
        }

        // Chats and their messages.
        let pinned = (try? Items.get(db, "pinnedConversationIds", as: [String].self)) ?? []
        var chatId: UInt64 = 1
        for row in conversations {
            let id: String = row["id"]
            guard let rid = recipientIds[id] else { continue }
            let messageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ? AND type IN ('incoming','outgoing')",
                                                arguments: [id]) ?? 0
            let j = Self.json(row["json"])
            guard messageCount > 0 || pinned.contains(id) else { continue }
            var chat = BackupProto_Chat()
            chat.id = chatId
            chat.recipientID = rid
            chat.archived = j["isArchived"] as? Bool ?? false
            if let i = pinned.firstIndex(of: id) { chat.pinnedOrder = UInt32(i + 1) }
            chat.expirationTimerMs = UInt64(((j["expireTimer"] as? NSNumber)?.intValue ?? 0) * 1000)
            chat.muteUntilMs = UInt64(max(0, (j["muteExpiresAt"] as? NSNumber)?.int64Value ?? 0))
            chat.markedUnread = j["markedUnread"] as? Bool ?? false
            let thisChat = chat
            let frame7 = Self.frame { f in f.chat = thisChat }
            frames.append(frame7)
            try addMessages(conversationId: id, chatId: chatId, selfId: selfId)
            chatId += 1
        }

        // Chat folders and notification profiles.
        for folder in try ChatFolderStore.current(db) {
            var c = BackupProto_ChatFolder()
            c.id = UUID(uuidString: folder.id)?.data ?? Data()
            c.name = folder.name
            c.showOnlyUnread = folder.showOnlyUnread
            c.showMutedChats = folder.showMutedChats
            c.includeAllIndividualChats = folder.includeAllIndividualChats
            c.includeAllGroupChats = folder.includeAllGroupChats
            c.folderType = folder.folderType == .all ? .all : .custom
            c.includedRecipientIds = folder.includedConversationIds.compactMap { recipientIds[$0] }
            c.excludedRecipientIds = folder.excludedConversationIds.compactMap { recipientIds[$0] }
            let frame8 = Self.frame { f in f.chatFolder = c }
            frames.append(frame8)
        }
        for profile in try NotificationProfiles.all(db) {
            var p = BackupProto_NotificationProfile()
            p.id = Data(hex: profile.id) ?? Data()
            p.name = profile.name
            p.emoji = profile.emoji ?? ""
            p.color = profile.color
            p.createdAtMs = UInt64(profile.createdAtMs)
            p.allowAllCalls = profile.allowAllCalls
            p.allowAllMentions = profile.allowAllMentions
            p.allowedMembers = profile.allowedMembers.compactMap { recipientIds[$0] }
            p.scheduleEnabled = profile.scheduleEnabled
            p.scheduleStartTime = UInt32(profile.scheduleStartTime ?? 0)
            p.scheduleEndTime = UInt32(profile.scheduleEndTime ?? 0)
            p.scheduleDaysEnabled = (1...7).filter { profile.scheduleDaysEnabled?[$0] == true }
                .compactMap { BackupProto_NotificationProfile.DayOfWeek(rawValue: $0) }
            let frame9 = Self.frame { f in f.notificationProfile = p }
            frames.append(frame9)
        }
        return (frames, media)
    }

    func pointer(_ a: MessageAttachment) -> BackupProto_FilePointer {
        var p = BackupProto_FilePointer()
        p.contentType = a.contentType
        p.fileName = a.fileName ?? ""
        p.width = UInt32(a.width ?? 0)
        p.height = UInt32(a.height ?? 0)
        p.caption = a.caption ?? ""
        p.blurHash = a.blurHash ?? ""
        var l = BackupProto_FilePointer.LocatorInfo()
        l.size = UInt32(a.size)
        if let key = a.key.flatMap({ Data(base64Encoded: $0) }) { l.key = key }
        if let hash = a.plaintextHash.flatMap({ Data(hex: $0) }) { l.plaintextHash = hash }
        if let cdn = a.cdnKey { l.transitCdnKey = cdn; l.transitCdnNumber = UInt32(a.cdnNumber ?? 0) }
        p.locatorInfo = l
        return p
    }

    mutating func addMessages(conversationId: String, chatId: UInt64, selfId: UInt64) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, type, sent_at, received_at, sourceServiceId, readStatus, expireTimer, json FROM messages
            WHERE conversationId = ? AND type IN ('incoming', 'outgoing') AND IFNULL(expireTimer, 0) = 0 AND storyId IS NULL
            ORDER BY received_at
            """, arguments: [conversationId])
        for row in rows {
            let messageId: String = row["id"]
            let j = Self.json(row["json"])
            let incoming = (row["type"] as String) == "incoming"
            var item = BackupProto_ChatItem()
            item.chatID = chatId
            if incoming {
                guard let author = try (row["sourceServiceId"] as String?).flatMap({ try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [$0]) }),
                      let aid = recipientIds[author] else { continue }
                item.authorID = aid
                var d = BackupProto_ChatItem.IncomingMessageDetails()
                d.dateReceived = UInt64((row["received_at"] as Int64?) ?? 0)
                d.dateServerSent = (j["serverTimestamp"] as? NSNumber)?.uint64Value ?? 0
                d.read = (row["readStatus"] as Int?) != ReadStatus.unread.rawValue
                d.sealedSender = j["unidentifiedDeliveryReceived"] as? Bool ?? false
                item.incoming = d
            } else {
                item.authorID = selfId
                var d = BackupProto_ChatItem.OutgoingMessageDetails()
                let states = j["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                for (conv, state) in states.sorted(by: { $0.key < $1.key }) {
                    guard let rid = recipientIds[conv] else { continue }
                    var s = BackupProto_SendStatus()
                    s.recipientID = rid
                    s.timestamp = (state["updatedAt"] as? NSNumber)?.uint64Value ?? 0
                    switch state["status"] as? String {
                    case "Viewed": s.viewed = BackupProto_SendStatus.Viewed()
                    case "Read": s.read = BackupProto_SendStatus.Read()
                    case "Delivered": s.delivered = BackupProto_SendStatus.Delivered()
                    case "Sent": s.sent = BackupProto_SendStatus.Sent()
                    case "Failed": s.failed = BackupProto_SendStatus.Failed()
                    default: s.pending = BackupProto_SendStatus.Pending()
                    }
                    d.sendStatus.append(s)
                }
                item.outgoing = d
            }
            item.dateSent = UInt64(row["sent_at"] as Int64)
            let attachments = try MessageAttachments.fetch(db, messageId: messageId).filter { $0.0.editHistoryIndex == -1 }
            let reactions = try Row.fetchAll(db, sql: "SELECT emoji, fromId, timestamp FROM reactions WHERE messageId = ? ORDER BY timestamp", arguments: [messageId])
                .enumerated().compactMap { i, r -> BackupProto_Reaction? in
                    guard let from: String = r["fromId"], let rid = recipientIds[from] else { return nil }
                    var x = BackupProto_Reaction()
                    x.emoji = r["emoji"] ?? ""
                    x.authorID = rid
                    x.sentTimestamp = UInt64((r["timestamp"] as Int64?) ?? 0)
                    x.sortOrder = UInt64(i)
                    return x
                }
            if let sticker = j["sticker"] as? [String: Any], let packId = sticker["packId"] as? String {
                var s = BackupProto_Sticker()
                s.packID = Data(hex: packId) ?? Data()
                s.packKey = Self.bytes(sticker["packKey"])
                s.stickerID = UInt32((sticker["stickerId"] as? NSNumber)?.intValue ?? 0)
                s.emoji = sticker["emoji"] as? String ?? ""
                if let a = attachments.first(where: { $0.0.type == .sticker })?.1 { s.data = pointer(a); media.append(a) }
                var m = BackupProto_StickerMessage()
                m.sticker = s
                m.reactions = reactions
                item.stickerMessage = m
            } else {
                var m = BackupProto_StandardMessage()
                let body = j["body"] as? String ?? ""
                if !body.isEmpty {
                    var t = BackupProto_Text()
                    t.body = body
                    t.bodyRanges = bodyRanges(j["bodyRanges"])
                    m.text = t
                }
                for (loc, a) in attachments where loc.type == .attachment {
                    var ma = BackupProto_MessageAttachment()
                    ma.pointer = pointer(a)
                    ma.flag = a.isVoiceMessage ? .voiceMessage : .none
                    ma.wasDownloaded = a.isDownloaded
                    if let uuid = a.clientUuid.flatMap(UUID.init(uuidString:)) { ma.clientUuid = uuid.data }
                    m.attachments.append(ma)
                    if a.isDownloaded { media.append(a) }
                }
                if let q = j["quote"] as? [String: Any], let author = q["authorAci"] as? String {
                    var quote = BackupProto_Quote()
                    quote.targetSentTimestamp = (q["id"] as? NSNumber)?.uint64Value ?? 0
                    quote.authorID = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [author])
                        .flatMap { recipientIds[$0] } ?? (author == account.aci ? selfId : 0)
                    if let text = q["text"] as? String {
                        var t = BackupProto_Text()
                        t.body = text
                        t.bodyRanges = bodyRanges(q["bodyRanges"])
                        quote.text = t
                    }
                    quote.type = .normal
                    if quote.authorID != 0 { m.quote = quote }
                }
                m.reactions = reactions
                guard m.hasText || !m.attachments.isEmpty else { continue }
                item.standardMessage = m
            }
            let finished = item
            let frame10 = Self.frame { f in f.chatItem = finished }
            frames.append(frame10)
        }
    }

    func bodyRanges(_ raw: Any?) -> [BackupProto_BodyRange] {
        (raw as? [[String: Any]] ?? []).compactMap { r in
            var b = BackupProto_BodyRange()
            b.start = UInt32((r["start"] as? NSNumber)?.intValue ?? 0)
            b.length = UInt32((r["length"] as? NSNumber)?.intValue ?? 0)
            if let aci = (r["mentionAci"] as? String).flatMap({ Self.aci($0) }) {
                b.mentionAci = aci
            } else if let style = (r["style"] as? NSNumber)?.intValue, let s = BackupProto_BodyRange.Style(rawValue: style) {
                b.style = s
            } else {
                return nil
            }
            return b
        }
    }
}
