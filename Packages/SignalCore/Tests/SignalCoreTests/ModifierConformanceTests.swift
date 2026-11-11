// Message modifiers: production SignalCore against the Lean model in Verification/Modifiers —
// `MessageModifiers.apply`'s decision for every kind on a real database (`randomDecisions`), whole
// runs of messages arriving, duplicated and removed while modifiers of every kind arrive before or
// after their targets, out of order and replayed (`randomRuns`: the stored messages, what they show
// and the waiting list), and the waiting list's evictions (`randomKept`).
//
// Run through Tools/verify-modifiers.sh, or set SEREIN_MODIFIERS_ORACLE to the oracle executable.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

enum ModifiersOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Modifiers").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_MODIFIERS_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-modifiers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// One world: four accounts (0 is us), their 1:1 conversations, groups 10 and 11.
struct ModifierWorld {
    var accounts: [String]
    var conversations: [Int: String]
    var groupIds: [Int: String]
    var ourAci: String { accounts[0] }

    static let hour: Int64 = 3_600_000
    static func ms(_ hours: Int) -> UInt64 { UInt64(1_000_000 + Int64(hours) * hour) }
    static let kinds: [PendingModifier.Kind] = [.delete, .adminDelete, .edit, .reaction, .pollVote, .pollTerminate, .pin, .unpin]
    static let sources: [ModifierSource] = [.someoneElse, .sync, .thisDevice]

    static func make(_ db: Database) throws -> ModifierWorld {
        let accounts = (0..<4).map { _ in UUID().uuidString.lowercased() }
        var conversations: [Int: String] = [:], groupIds: [Int: String] = [:]
        for a in 0..<4 { conversations[a] = try MessageStore.privateConversation(db, serviceId: accounts[a]) }
        for g in [10, 11] {
            let keys = try GroupKeys(masterKey: SignalCrypto.randomBytes(32))
            let id = try GroupStore.conversation(db, keys: keys).conversationId
            conversations[g] = id
            groupIds[g] = try String.fetchOne(db, sql: "SELECT groupId FROM conversations WHERE id = ?", arguments: [id])
        }
        return ModifierWorld(accounts: accounts, conversations: conversations, groupIds: groupIds)
    }

    /// Sets the groups' members, administrators and attribute access, and the block lists;
    /// returns the oracle's notation.
    func set(_ db: Database, _ r: inout SplitMix) throws -> String {
        var code: [String] = []
        for g in [10, 11] {
            let members = (0..<4).filter { _ in r.coin() }
            let admins = members.filter { _ in r.coin() }
            // Attribute access: mostly members or administrators, sometimes unknown, any, unsatisfiable.
            let levels = [GroupAccess.member, GroupAccess.administrator, GroupAccess.unknown, GroupAccess.any, GroupAccess.unsatisfiable]
            let attributes = levels[r.coin() ? r.below(2) : r.below(5)]
            let open = attributes == GroupAccess.member
            var state = GroupV2State()
            state.membersV2 = members.map {
                GroupMember(aci: accounts[$0], role: admins.contains($0) ? GroupRole.administrator : GroupRole.default, joinedAtVersion: 0)
            }
            state.accessControl.attributes = attributes
            try GroupStore.save(db, conversationId: conversations[g]!, state: state, ourAci: ourAci)
            code += [list(members), list(admins), open ? "1" : "0"]
        }
        let blocked = [1, 2, 3].filter { _ in r.coin(5) }
        let blockedGroups = [10, 11].filter { _ in r.coin(5) }
        try BlockedList.serviceIds.save(db, blocked.map { (accounts[$0], nil) })
        try BlockedList.groups.save(db, blockedGroups.map { (groupIds[$0]!, nil) })
        return (code + [list(blocked), list(blockedGroups)]).joined(separator: " ")
    }

    struct Message {
        var author, sentAt, conv, server: Int
        var sentTo: [Int]
        var viewOnce, voice, poll, giftBadge: Bool
        var outgoing: Bool { author == 0 }
        var code: String {
            "\(author) \(sentAt) \(conv) \(server) \(outgoing ? 1 : 0) \(list(sentTo)) \(viewOnce ? 1 : 0) \(voice ? 1 : 0) \(poll ? 1 : 0)"
        }
    }

    static func randomMessage(_ r: inout SplitMix, sentAt: Int, server: Int) -> Message {
        let author = r.below(4)
        let conv = author == 0 ? [0, 1, 2, 3, 10, 11][r.below(6)] : [author, 10, 11][r.below(3)]
        return Message(author: author, sentAt: sentAt, conv: conv, server: server, sentTo: [1, 2, 3].filter { _ in r.coin() },
                       viewOnce: r.coin(8), voice: r.coin(8), poll: r.coin(3), giftBadge: r.coin(8))
    }

    @discardableResult
    func insert(_ db: Database, _ m: Message) throws -> String {
        var extra: [String: Any] = [:]
        if m.viewOnce { extra["isViewOnce"] = true }
        if m.poll { extra["poll"] = ["question": "q", "options": ["a", "b"], "allowMultiple": false, "votes": [[String: Any]]()] as [String: Any] }
        if m.giftBadge { extra["giftBadge"] = ["level": 1] }
        if m.outgoing {
            var states: [String: Any] = [:]
            for a in m.sentTo { states[conversations[a]!] = ["status": "Sent"] }
            extra["sendStateByConversationId"] = states
        }
        let type = m.outgoing ? "outgoing" : "incoming"
        let id = try MessageStore.insert(db, .init(conversationId: conversations[m.conv]!, type: type, body: "b\(m.sentAt)", sentAt: UInt64(m.sentAt),
                                                   source: accounts[m.author], sourceDevice: 1, serverGuid: nil, serverTimestamp: Self.ms(m.server),
                                                   unidentified: false, extra: extra))
        if m.voice {
            var a = MessageAttachment(contentType: "audio/aac", size: 10)
            a.flags = MessageAttachment.flagVoiceMessage
            try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversations[m.conv]!,
                                          sentAt: Int64(m.sentAt), receivedAt: 0, messageType: type, a)
        }
        return id
    }

    struct Modifier: Equatable {
        var kind, sender, conv, src, author, target, ts, server: Int
        var code: String { "\(kind) \(sender) \(conv) \(src) \(author) \(target) \(ts) \(server)" }
    }

    func pending(_ m: Modifier) throws -> PendingModifier {
        var payload = Data()
        switch Self.kinds[m.kind] {
        case .edit:
            var e = Signalservice_EditMessage()
            e.targetSentTimestamp = UInt64(m.target)
            e.dataMessage.timestamp = UInt64(m.ts)
            e.dataMessage.body = "b\(m.ts)"
            payload = try e.serializedBytes()
        case .reaction:
            var x = Signalservice_DataMessage.Reaction()
            x.emoji = "x"
            x.targetSentTimestamp = UInt64(m.target)
            payload = try x.serializedBytes()
        case .pollVote:
            var v = Signalservice_DataMessage.PollVote()
            v.optionIndexes = [0]
            v.voteCount = UInt32(m.ts)
            v.targetSentTimestamp = UInt64(m.target)
            payload = try v.serializedBytes()
        case .pin:
            var p = Signalservice_DataMessage.PinMessage()
            p.pinDurationForever = true
            payload = try p.serializedBytes()
        default: break
        }
        let context = ModifierContext(sender: accounts[m.sender], timestamp: UInt64(m.ts), serverTimestamp: Self.ms(m.server),
                                      conversationId: conversations[m.conv]!, source: Self.sources[m.src])
        return PendingModifier(kind: Self.kinds[m.kind], targetAuthor: accounts[m.author], targetSentAt: UInt64(m.target), context: context,
                               payload: payload, storedAt: MessageStore.now())
    }

    @discardableResult
    func apply(_ db: Database, _ m: Modifier) throws -> String? {
        try MessageModifiers.apply(db, try pending(m), ourAci: ourAci, keepIfMissing: m.src != 2)
    }

    /// The stored messages (arrival order) and the waiting list, in the oracle's notation; and
    /// whether each shows the content of the revision it reports.
    func state(_ db: Database) throws -> (String, [String]) {
        var rows: [String] = [], issues: [String] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT id, json, sourceServiceId, sent_at FROM messages WHERE type IN ('incoming', 'outgoing') AND sourceServiceId IN (?, ?, ?, ?)
            ORDER BY received_at
            """, arguments: StatementArguments(accounts)) {
            let json = try MessageStore.jsonObject(row["json"])
            let id: String = row["id"]
            let sentAt: Int64 = row["sent_at"]
            let deleted = json["deletedForEveryone"] as? Bool ?? false
            let rev = max(sentAt, (json["editMessageTimestamp"] as? NSNumber)?.int64Value ?? 0)
            let revs = try Int64.fetchAll(db, sql: "SELECT sentAt FROM edited_messages WHERE messageId = ? ORDER BY sentAt", arguments: [id])
            let pinned = try Int.fetchOne(db, sql: "SELECT 1 FROM pinnedMessages WHERE messageId = ?", arguments: [id]) != nil
            let poll = json["poll"] as? [String: Any]
            let author = accounts.firstIndex(of: row["sourceServiceId"])!
            rows.append("\(author):\(sentAt):\(deleted ? 1 : 0):\(rev):\(revs.isEmpty ? "-" : revs.map(String.init).joined(separator: ".")):"
                        + "\(pinned ? 1 : 0):\(poll != nil ? 1 : 0):\(poll?["terminatedAt"] != nil ? 1 : 0)")
            let body = json["body"] as? String
            if deleted ? body != nil : body != "b\(rev)" { issues.append("\(author):\(sentAt) shows \(body ?? "nothing") at revision \(rev)") }
        }
        let waiting = try Items.get(db, MessageModifiers.pendingKey, as: [PendingModifier].self) ?? []
        let pending = waiting.map { "\(Self.kinds.firstIndex(of: $0.kind)!):\(accounts.firstIndex(of: $0.targetAuthor) ?? 9):\($0.targetSentAt)" }
        return ("\(rows.isEmpty ? "-" : rows.joined(separator: " ")) | \(pending.isEmpty ? "-" : pending.joined(separator: " "))", issues)
    }
}

@Suite(.serialized, .enabled(if: ModifiersOracle.available, "build the oracle: Tools/verify-modifiers.sh, or lake build in Verification/Modifiers"))
struct ModifierConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_MODIFIERS_CASES"].flatMap { Int($0) } ?? 2000 }

    static func database() throws -> SignalDatabase {
        let (db, _) = try LinkedClient.temporaryDatabase()
        try db.pool.write { db in
            // Pins are not limited here: the limit's evictions are not modelled.
            try Items.set(db, "remoteConfig", ["global.pinnedMessageLimit": RemoteConfig.Value(name: "global.pinnedMessageLimit", enabled: true,
                                                                                               value: "1000", enabledAt: nil)])
        }
        return db
    }

    /// One message in a random state, one modifier naming it: is it accepted?
    @Test func randomDecisions() async throws {
        let database = try Self.database()
        let count = Self.count
        let (lines, swift) = try await database.pool.write { db -> ([String], [String]) in
            var r = SplitMix(s: 61)
            var lines: [String] = [], swift: [String] = []
            let w = try ModifierWorld.make(db)
            for i in 0..<count {
                let world = try w.set(db, &r)
                let sentAt = 1000 * (i + 1)
                let m = ModifierWorld.randomMessage(&r, sentAt: sentAt, server: 100 + r.below(20))
                let id = try w.insert(db, m)
                var rev = sentAt
                if r.coin(4) {
                    rev = sentAt + 1 + r.below(3)
                    _ = try MessageStore.applyEdit(db, author: w.accounts[m.author], targetSentAt: UInt64(sentAt), newBody: "b\(rev)", editSentAt: UInt64(rev))
                }
                var pinned = r.coin(4), poll = m.poll, terminated = false
                if pinned {
                    try db.execute(sql: "INSERT INTO pinnedMessages (conversationId, messageId, pinnedAt, expiresAt) VALUES (?, ?, 1, NULL)",
                                   arguments: [w.conversations[m.conv]!, id])
                }
                if poll && r.coin(4) {
                    terminated = true
                    try MessageStore.updateJSON(db, messageId: id) { json in
                        var p = json["poll"] as? [String: Any] ?? [:]
                        p["terminatedAt"] = 5
                        json["poll"] = p
                    }
                }
                let deleted = r.coin(8), erased = deleted || r.coin(8)
                if erased {
                    try MessageModifiers.erase(db, id) { json in if deleted { json["deletedForEveryone"] = true } }
                    pinned = false
                    poll = false
                }
                let sender = r.below(4)
                let src = sender == 0 ? r.below(3) : (r.coin(10) ? r.below(3) : 0)
                let kind = r.below(8)
                let ts = kind >= 6 ? sentAt + 500 + r.below(9) : sentAt - 2 + r.below(9)
                let conv = r.coin(3) ? [0, 1, 2, 3, 10, 11][r.below(6)] : m.conv
                let mod = ModifierWorld.Modifier(kind: kind, sender: sender, conv: conv, src: src, author: m.author, target: sentAt, ts: ts,
                                                 server: max(0, m.server - 70 + r.below(141)))
                let row = "\(m.author) \(sentAt) \(m.conv) \(m.server) \(m.outgoing ? 1 : 0) \(list(m.sentTo)) \(m.viewOnce ? 1 : 0) \(m.voice ? 1 : 0) "
                    + "\(poll ? 1 : 0) \(terminated ? 1 : 0) \(m.giftBadge && !erased ? 1 : 0) \(pinned ? 1 : 0) \(deleted ? 1 : 0) \(erased ? 1 : 0) \(rev)"
                lines.append("\(world) | \(row) | \(mod.code)")
                swift.append(try w.apply(db, mod) != nil ? "1" : "0")
            }
            return (lines, swift)
        }
        compare(lines, model: try ModifiersOracle.call("decide", lines), swift: swift)
    }

    /// Runs: messages arrive (and again), are removed; modifiers of every kind arrive before or
    /// after their targets, out of order, replayed, naming the message or one of its edits.
    @Test func randomRuns() async throws {
        let database = try Self.database()
        let runs = max(1, Self.count / 10)
        let (lines, swift, issues) = try await database.pool.write { db -> ([String], [String], [String]) in
            var r = SplitMix(s: 67)
            var lines: [String] = [], swift: [String] = [], issues: [String] = []
            for _ in 0..<runs {
                let w = try ModifierWorld.make(db)
                let world = try w.set(db, &r)
                try Items.set(db, MessageModifiers.pendingKey, [PendingModifier]())
                var clock = 0
                func tick() -> Int { clock += 1; return clock }
                let messages = (0..<4).map { _ in ModifierWorld.randomMessage(&r, sentAt: tick(), server: 100 + r.below(20)) }
                var edits: [Int: [Int]] = [:]
                var sent: [ModifierWorld.Modifier] = [], held: [ModifierWorld.Modifier] = []
                var events: [String] = []
                func modifier() -> ModifierWorld.Modifier {
                    let i = r.below(messages.count), m = messages[i]
                    let kind = r.below(8)
                    let byAuthor = kind == 0 || kind == 2 || kind == 5
                    let sender = byAuthor && r.coin(5) == false ? m.author : r.below(4)
                    let author = byAuthor ? sender : (r.coin(10) ? r.below(4) : m.author)
                    var target = m.sentAt
                    if let e = edits[i], !e.isEmpty, r.coin(3) { target = e[r.below(e.count)] }
                    if r.coin(20) { target = 900 + r.below(10) }
                    let ts = kind >= 6 ? 10_000 + tick() : tick()
                    if kind == 2 { edits[i, default: []].append(ts) }
                    let src = sender == 0 ? (r.coin(5) ? 0 : 1 + r.below(2)) : 0
                    return .init(kind: kind, sender: sender, conv: r.coin(4) ? [0, 1, 2, 3, 10, 11][r.below(6)] : m.conv, src: src, author: author,
                                 target: target, ts: ts, server: max(0, m.server - 60 + r.below(121)))
                }
                for _ in 0..<30 {
                    let k = r.below(20)
                    if k < 6 {
                        let m = messages[r.below(messages.count)]
                        events.append("r \(m.code) \(m.giftBadge ? 1 : 0)")
                        if try MessageStore.find(db, author: w.accounts[m.author], sentAt: UInt64(m.sentAt)) == nil {
                            try w.insert(db, m)
                            try MessageModifiers.applyPending(db, author: w.accounts[m.author], sentAt: UInt64(m.sentAt), ourAci: w.ourAci)
                        }
                    } else if k == 6 {
                        let m = messages[r.below(messages.count)]
                        events.append("f \(m.author) \(m.sentAt)")
                        if let id = try MessageStore.find(db, author: w.accounts[m.author], sentAt: UInt64(m.sentAt)) { try DeleteForMe.deleteMessage(db, id) }
                    } else {
                        var mod: ModifierWorld.Modifier
                        if !sent.isEmpty, r.coin(7) { mod = sent[r.below(sent.count)] }        // replayed
                        else if !held.isEmpty, r.coin(3) { mod = held.remove(at: r.below(held.count)) }   // late
                        else {
                            mod = modifier()
                            if r.coin(4) { held.append(mod); continue }
                        }
                        sent.append(mod)
                        events.append("m \(mod.code)")
                        try w.apply(db, mod)
                    }
                }
                lines.append("\(world) | \(events.joined(separator: " ; "))")
                let (state, wrong) = try w.state(db)
                issues += wrong
                swift.append(state)
            }
            return (lines, swift, issues)
        }
        for issue in issues.prefix(3) { Issue.record("content: \(issue)") }
        compare(lines, model: try ModifiersOracle.call("run", lines), swift: swift)
    }

    /// The waiting list after one more joins it: ages, the limit, who is evicted.
    @Test func randomKept() throws {
        var r = SplitMix(s: 71)
        var lines: [String] = [], swift: [String] = []
        let senders = (0..<4).map { _ in UUID().uuidString.lowercased() }
        func entry(_ i: Int, _ s: Int, _ at: Int) -> PendingModifier {
            PendingModifier(kind: .reaction, targetAuthor: senders[0], targetSentAt: UInt64(i),
                            context: ModifierContext(sender: senders[s], timestamp: 1, serverTimestamp: 1, conversationId: "c", source: .someoneElse),
                            payload: Data(), storedAt: Int64(at) * ModifierWorld.hour)
        }
        for _ in 0..<Self.count {
            let n = r.below(14), limit = r.below(12), now = r.below(130)
            let olds = (0..<n).map { _ in (r.coin(3) ? 0 : r.below(4), r.below(120)) }
            let new = (r.below(4), now)
            lines.append("\(limit) \(now) | \(olds.isEmpty ? "-" : olds.map { "\($0.0):\($0.1)" }.joined(separator: " ")) | \(new.0):\(new.1)")
            let kept = MessageModifiers.kept(olds.enumerated().map { entry($0.offset, $0.element.0, $0.element.1) }, adding: entry(n, new.0, new.1),
                                             limit: limit, now: Int64(now) * ModifierWorld.hour)
            swift.append(list(kept.map { Int($0.targetSentAt) }))
        }
        compare(lines, model: try ModifiersOracle.call("kept", lines), swift: swift)
    }
}
