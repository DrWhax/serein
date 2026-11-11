// Send authorization: production SignalCore's decisions against the Lean model in
// Verification/Send, on random database states and random payloads:
// `MessageSender.authorization` (what the transport checks immediately before each submission),
// `OutgoingPayload.onlyRetracts` (the retraction exemption), and `GroupSender`'s recipients.
// Payloads are real protobufs with random fields; the rig maps each to the model's notation by
// its own reading of the fields (`DataFields`), which is the specification of "content".
//
// Run through Tools/verify-send.sh, or set SEREIN_SEND_ORACLE to the oracle executable.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

enum SendOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Send").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_SEND_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func decide(_ cases: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((cases.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["decide"]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

struct SplitMix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func coin(_ oneIn: Int = 2) -> Bool { below(oneIn) == 0 }
}

/// A random DataMessage, with the model's reading of it: does it delete, and does it have any
/// field beyond the delete and the envelope (timestamp, profile key, group context)?
func randomData(_ r: inout SplitMix) -> (Signalservice_DataMessage, retract: Bool, extra: Bool) {
    var m = Signalservice_DataMessage()
    if r.coin() { m.timestamp = 1_700_000_000_000 }
    if r.coin() { m.profileKey = Data(repeating: 7, count: 32) }
    if r.coin() {
        var g = Signalservice_GroupContextV2()
        g.masterKey = Data(repeating: 9, count: 32)
        g.revision = 4
        m.groupV2 = g
    }
    var retract = false
    switch r.below(4) {
    case 0, 1:
        var d = Signalservice_DataMessage.Delete()
        d.targetSentTimestamp = 1_699_999_999_000
        m.delete = d
        retract = true
    case 2:
        var d = Signalservice_DataMessage.AdminDelete()
        d.targetSentTimestamp = 1_699_999_999_000
        d.targetAuthorAciBinary = Data(repeating: 3, count: 16)
        m.adminDelete = d
        retract = true
    default: break
    }
    // Content: each field with some probability; any one of them is "extra".
    var extra = false
    let n = r.coin(3) ? 0 : 1 + r.below(2)
    for _ in 0..<n {
        extra = true
        switch r.below(12) {
        case 0: m.body = "hello"
        case 1:
            var a = Signalservice_AttachmentPointer()
            a.cdnKey = "k"
            a.contentType = "image/jpeg"
            m.attachments = [a]
        case 2:
            var q = Signalservice_DataMessage.Quote()
            q.id = 1
            q.text = "quoted"
            m.quote = q
        case 3:
            var re = Signalservice_DataMessage.Reaction()
            re.emoji = "👍"
            re.targetSentTimestamp = 1
            m.reaction = re
        case 4:
            var s = Signalservice_DataMessage.Sticker()
            s.packID = Data(repeating: 1, count: 16)
            s.stickerID = 2
            m.sticker = s
        case 5:
            var p = Signalservice_Preview()
            p.url = "https://example.com"
            m.preview = [p]
        case 6: m.expireTimer = 3600
        case 7: m.isViewOnce = true
        case 8:
            var b = Signalservice_BodyRange()
            b.start = 0
            b.length = 1
            m.bodyRanges = [b]
        case 9: m.flags = 1
        case 10:
            var sc = Signalservice_DataMessage.StoryContext()
            sc.sentTimestamp = 5
            m.storyContext = sc
        default: m.requiredProtocolVersion = 1
        }
    }
    return (m, retract, extra)
}

/// A random payload and its model notation (`Content.code` in Send/Trace.lean).
func randomContent(_ r: inout SplitMix) -> (Signalservice_Content, String) {
    var c = Signalservice_Content()
    switch r.below(6) {
    case 0, 1:
        let (m, retract, extra) = randomData(&r)
        c.dataMessage = m
        return (c, "data.\(retract ? 1 : 0).\(extra ? 1 : 0)")
    case 2, 3:
        var sent = Signalservice_SyncMessage.Sent()
        sent.timestamp = 1_700_000_000_000
        if r.coin() { sent.destinationServiceID = UUID().uuidString.lowercased() }
        var msg = "-.-"
        if r.coin(3) == false {
            let (m, retract, extra) = randomData(&r)
            sent.message = m
            msg = "\(retract ? 1 : 0).\(extra ? 1 : 0)"
        }
        let update = r.coin()
        if update { sent.isRecipientUpdate = true }
        if r.coin() {
            var rec = Signalservice_SyncMessage.Sent.StoryMessageRecipient()
            rec.destinationServiceID = UUID().uuidString.lowercased()
            rec.distributionListIds = ["l"]
            sent.storyMessageRecipients = [rec]
        }
        let story = r.coin(4)
        if story {
            var s = Signalservice_StoryMessage()
            var t = Signalservice_TextAttachment()
            t.text = "story"
            s.textAttachment = t
            sent.storyMessage = s
        }
        let edit = r.coin(5)
        if edit {
            var e = Signalservice_EditMessage()
            e.targetSentTimestamp = 1
            var d = Signalservice_DataMessage()
            d.body = "edited"
            e.dataMessage = d
            sent.editMessage = e
        }
        var sync = Messenger.syncMessage()
        sync.sent = sent
        c.syncMessage = sync
        return (c, "sent.\(msg).\(update ? 1 : 0).\(story ? 1 : 0).\(edit ? 1 : 0)")
    case 4:
        if r.coin() {
            var e = Signalservice_EditMessage()
            e.targetSentTimestamp = 1
            var d = Signalservice_DataMessage()
            d.body = "edited"
            e.dataMessage = d
            c.editMessage = e
        } else {
            var s = Signalservice_StoryMessage()
            var t = Signalservice_TextAttachment()
            t.text = "story"
            s.textAttachment = t
            c.storyMessage = s
        }
        return (c, "content")
    default:
        switch r.below(3) {
        case 0:
            var t = Signalservice_TypingMessage()
            t.timestamp = 1
            t.action = .started
            c.typingMessage = t
        case 1:
            var rm = Signalservice_ReceiptMessage()
            rm.type = .read
            rm.timestamp = [1]
            c.receiptMessage = rm
        default:
            var sync = Messenger.syncMessage()
            var read = Signalservice_SyncMessage.Read()
            read.timestamp = 1
            sync.read = [read]
            c.syncMessage = sync
        }
        return (c, "other")
    }
}

@Suite(.serialized, .enabled(if: SendOracle.available, "build the oracle: Tools/verify-send.sh, or lake build in Verification/Send"))
struct SendAuthorizationConformanceTests {
    @Test func randomDecisions() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let ourAci = UUID().uuidString.lowercased()
        let account = Account(aci: ourAci, pni: nil, number: "+14155550100", deviceId: 2, password: "pw", deviceName: "rig",
                              aciIdentity: .generate(), pniIdentity: nil, aciRegistrationId: 1, pniRegistrationId: nil, profileKey: nil,
                              masterKey: nil, accountEntropyPool: nil, readReceipts: false)
        let socket = SocketManager(net: Net(env: .staging, userAgent: "SignalSafe-Tests", buildVariant: .production))
        let sender = MessageSender(account: account, database: db, socket: socket, trustRoots: [])
        let contacts = (0..<3).map { _ in UUID().uuidString.lowercased() }
        let numbers = (0..<3).map { "+1415555020\($0)" }
        let groupId = Data(repeating: 5, count: 32)
        let conversation = try await db.pool.write { db -> String in
            for (aci, number) in zip(contacts, numbers) {
                _ = try MessageStore.privateConversation(db, serviceId: aci)
                try db.execute(sql: "UPDATE conversations SET e164 = ? WHERE serviceId = ?", arguments: [number, aci])
            }
            return try MessageStore.privateConversation(db, serviceId: contacts[0])
        }

        var r = SplitMix(s: 20261111)
        let count = ProcessInfo.processInfo.environment["SEREIN_SEND_CASES"].flatMap { Int($0) } ?? 3000
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<count {
            // The state: blocked contacts (by id, by number), the group, four messages.
            let byId = (0..<3).filter { _ in r.coin(4) }, byNumber = (0..<3).filter { _ in r.coin(5) }, group = r.coin(4)
            let states = (0..<4).map { _ in ["L", "L", "E", "G"][r.below(4)] }
            let ids = try await db.pool.write { db -> [String] in
                try BlockedList.serviceIds.save(db, byId.map { (contacts[$0], nil) })
                try BlockedList.numbers.save(db, byNumber.map { (numbers[$0], nil) })
                try BlockedList.groups.save(db, group ? [(groupId.base64EncodedString(), nil)] : [])
                try db.execute(sql: "DELETE FROM messages")
                return try states.map { st in
                    let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "outgoing", body: "m", sentAt: 1, source: ourAci,
                                                              sourceDevice: 2, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                    if st == "E" { try MessageStore.updateJSON(db, messageId: id) { $0["isErased"] = true } }
                    if st == "G" { try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id]) }
                    return id
                }
            }
            let (content, code) = randomContent(&r)
            let payload = OutgoingPayload(content: content, timestamp: 1)
            let named = (0..<4).filter { _ in r.coin(3) }
            let target = r.below(5)
            let (to, gid, tcode): (String?, Data, String) = switch target {
            case 0, 1, 2: (contacts[target], Data(), "d\(target)")
            case 3: (ourAci, Data(), "self")
            default: (nil, groupId, "g0")
            }
            let list = { (xs: [Int]) in xs.isEmpty ? "-" : xs.map(String.init).joined(separator: ",") }
            lines.append("\(list(byId)) \(list(byNumber)) \(group ? "0" : "-") \(states.joined()) 0,1,2 | \(tcode) \(code) \(list(named))")
            let authorized = (try? sender.authorization(to: to, groupId: gid, messageIds: named.map { ids[$0] }, retracting: payload.onlyRetracts)()) != nil
            let recipients = target == 4
                ? try await db.pool.read { db in try GroupSender.sendableRecipients(db, contacts) }.compactMap { contacts.firstIndex(of: $0) }
                : []
            swift.append("\(authorized ? 1 : 0) \(payload.onlyRetracts ? 1 : 0) [\(recipients.map(String.init).joined(separator: ","))]")
        }
        let model = try SendOracle.decide(lines)
        #expect(model.count == lines.count)
        var reported = 0
        for (k, (m, s)) in zip(model, swift).enumerated() {
            // The model also prints `carries`; production has no such function to compare.
            let mf = m.split(separator: " "), mine = "\(mf[0]) \(mf[1]) \(mf[3])"
            guard mine != s else { continue }
            reported += 1
            if reported <= 3 { Issue.record("disagree at step \(k) (\(lines[k]))\n  model \(mine) | swift \(s)") }
        }
        #expect(reported == 0, "\(reported) of \(lines.count) cases disagree")
    }

    /// The payloads production builds for a delete for everyone (ours and, as an admin, someone
    /// else's) and for a story delete's recipient update qualify as retractions: an authorized
    /// retraction is not refused because its message is gone.
    @Test func productionRetractionsQualify() throws {
        var data = Signalservice_DataMessage()
        data.timestamp = 1
        data.profileKey = Data(repeating: 1, count: 32)
        var ctx = Signalservice_GroupContextV2()
        ctx.masterKey = Data(repeating: 2, count: 32)
        data.groupV2 = ctx
        var d = Signalservice_DataMessage.Delete()
        d.targetSentTimestamp = 5
        data.delete = d
        var c = Signalservice_Content()
        c.dataMessage = data
        #expect(OutgoingPayload(content: c, timestamp: 1).onlyRetracts)
        var admin = data
        admin.clearDelete()
        var a = Signalservice_DataMessage.AdminDelete()
        a.targetSentTimestamp = 5
        admin.adminDelete = a
        c.dataMessage = admin
        #expect(OutgoingPayload(content: c, timestamp: 1).onlyRetracts)
        var sent = Signalservice_SyncMessage.Sent()
        sent.timestamp = 5
        sent.isRecipientUpdate = true
        var rec = Signalservice_SyncMessage.Sent.StoryMessageRecipient()
        rec.distributionListIds = ["x"]
        sent.storyMessageRecipients = [rec]
        var sync = Messenger.syncMessage()
        sync.sent = sent
        var s = Signalservice_Content()
        s.syncMessage = sync
        #expect(OutgoingPayload(content: s, timestamp: 1).onlyRetracts)
        // …and a delete with a body is not one.
        data.body = "hi"
        c.dataMessage = data
        #expect(!OutgoingPayload(content: c, timestamp: 1).onlyRetracts)
    }
}

/// The submission boundary: every transport path runs the authorization check after setting up
/// the connection and immediately before handing the request to libsignal, and a refusal there
/// sends nothing.
@Suite struct SubmissionBoundaryTests {
    struct Refused: Error {}

    @Test func transportRefusesAtTheBoundary() async throws {
        try await LinkedClient.with { c in
            await #expect(throws: Refused.self) {
                _ = try await c.socket.authenticatedRequest("GET", "/v1/devices/", authorize: { throw Refused() })
            }
            await #expect(throws: Refused.self) {
                _ = try await c.socket.unauthenticatedRequest("GET", "/v1/config", authorize: { throw Refused() })
            }
            await #expect(throws: Refused.self) {
                _ = try await c.socket.sendMultiRecipient(Data(), timestamp: 1, token: Data(), online: false, urgent: false, authorize: { throw Refused() })
            }
        }
    }
}
