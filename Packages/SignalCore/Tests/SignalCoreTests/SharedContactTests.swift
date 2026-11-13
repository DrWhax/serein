// Shared contacts (DataMessage.Contact): received and shown, and sent with an avatar
// (enqueueSharedContactForSend), against the mock server.

import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct SharedContactTests {
    func timelineMessage(_ c: LinkedClient, _ id: String) async throws -> TimelineMessage {
        try await c.database.pool.read { db in
            let conversationId = try #require(try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]))
            return try #require(try ConversationQueries.messages(db, conversationId: conversationId).first { $0.id == id })
        }
    }

    @Test func aReceivedContactIsKeptAndShown() async throws {
        try await LinkedClient.with { c in
            let t = try await c.send(["contact": ["name": ["givenName": "Bob", "familyName": "Roberts"], "organization": "Acme",
                                                  "number": [["value": "+15555550101", "type": 2]], "aci": "alice", "note": "met at the fair"]])
            let m = try await timelineMessage(c, try await c.messageId(sentAt: t))
            let contact = try #require(m.contact)
            #expect(contact.givenName == "Bob" && contact.familyName == "Roberts" && contact.organization == "Acme")
            #expect(contact.numbers == [SharedContactInfo.Method(value: "+15555550101", type: 2)])
            // (The mock server's protos predate aciBinary, nickname and note: see fullContactRoundTrips.)
        }
    }

    @Test func aContactIsSentWithItsAvatar() async throws {
        try await LinkedClient.with { c in
            var bob = SharedContactInfo(givenName: "Bob", familyName: "Roberts")
            bob.numbers = [.init(value: "+15555550101", type: 4)]
            bob.aci = c.aliceAci
            bob.avatarIsProfile = true
            let avatar = OutgoingAttachment(data: AttachmentFlowTests.png(), contentType: "image/png")
            let (id, _) = try await c.messenger.sendMessage("", attachments: [], to: c.aliceAci, contact: bob, contactAvatar: avatar)
            let got = try await c.server.json("waitForMessage", ["account": "alice"])
            let card = try #require((got["contact"] as? [[String: Any]])?.first)
            #expect(card["givenName"] as? String == "Bob" && card["familyName"] as? String == "Roberts")
            #expect((card["number"] as? [[String: Any]])?.first?["value"] as? String == "+15555550101")
            let sentAvatar = try #require(card["avatar"] as? [String: Any])
            #expect(sentAvatar["contentType"] as? String == "image/png" && sentAvatar["isProfile"] as? Bool == true)
            // Ours shows it too, with the avatar.
            let m = try await timelineMessage(c, id)
            #expect(m.contact?.givenName == "Bob" && m.contact?.avatar != nil)
        }
    }

    /// "Message" on a shared contact (`lookupOrCreateConversationIdForSharedContact`): their
    /// chat, created with the shared name when only the ACI is known; none when not on Signal.
    @Test func messagingASharedContactOpensTheirChat() async throws {
        try await LinkedClient.with { c in
            var nina = SharedContactInfo(givenName: "Nina", familyName: "New")
            nina.aci = "88888888-8888-4888-8888-888888888888"
            let created = try #require(try await c.messenger.conversation(forSharedContact: nina))
            #expect(created.serviceId == nina.aci)
            let again = try #require(try await c.messenger.conversation(forSharedContact: nina))
            #expect(again.id == created.id)
            let title = try await c.database.pool.read { db in try ConversationQueries.conversation(db, id: created.id)?.title }
            #expect(title == "Nina New")
            var nobody = SharedContactInfo(givenName: "Z")
            nobody.numbers = [.init(value: "+15555550999", type: 4)]
            #expect(try await c.messenger.conversation(forSharedContact: nobody) == nil)
        }
    }

    /// Every field, through the proto and the stored form and back (`processContact`, `toContactProto`).
    @Test func fullContactRoundTrips() throws {
        var p = Signalservice_DataMessage.Contact()
        var name = Signalservice_DataMessage.Contact.Name()
        name.givenName = "Bob"; name.familyName = "Roberts"; name.middleName = "Q"; name.nickname = "Bobby"
        p.name = name
        var phone = Signalservice_DataMessage.Contact.Phone()
        phone.value = "+15555550101"; phone.type = .mobile; phone.label = "cell"
        var blank = Signalservice_DataMessage.Contact.Phone()
        blank.type = .home      // no value: dropped, as upstream
        p.number = [phone, blank]
        var email = Signalservice_DataMessage.Contact.Email()
        email.value = "bob@example.com"; email.type = .work
        p.email = [email]
        var address = Signalservice_DataMessage.Contact.PostalAddress()
        address.type = .work; address.street = "1 Main St"; address.city = "Springfield"
        p.address = [address]
        p.organization = "Acme"
        let aci = "8c0a1e64-9f4b-4b8e-9a54-2f1d3c4b5a69"
        p.aciBinary = try #require(StorageLocal.uuidBytes(aci))
        var nick = Signalservice_DataMessage.Contact.SignalNickname()
        nick.given = "B"; nick.family = "R"
        p.nickname = nick
        p.note = "met at the fair"
        let stored = SharedContacts.json(p)
        let info = SharedContacts.info(stored)
        #expect(info.givenName == "Bob" && info.middleName == "Q" && info.nickname == "Bobby" && info.organization == "Acme")
        #expect(info.numbers == [.init(value: "+15555550101", type: 2, label: "cell")])
        #expect(info.emails == [.init(value: "bob@example.com", type: 3)])
        #expect(info.addresses.first?.street == "1 Main St" && info.addresses.first?.type == 2)
        #expect(info.aci == aci && info.signalNicknameGiven == "B" && info.signalNicknameFamily == "R" && info.note == "met at the fair")
        let back = SharedContacts.proto(SharedContacts.json(info, hasAvatar: false), avatar: nil)
        #expect(back.name.givenName == "Bob" && back.number.count == 1 && back.number[0].type == .mobile && back.number[0].label == "cell")
        #expect(back.aciBinary == p.aciBinary && back.nickname.given == "B" && back.note == "met at the fair" && back.organization == "Acme")
    }

    /// `canShareContact`: a name and an ACI, or a number.
    @Test func aContactNeedsANameAndAciOrANumber() async throws {
        try await LinkedClient.with { c in
            await #expect(throws: SharedContactError.needsNameAndAciOrNumber) {
                try await c.messenger.sendMessage("", attachments: [], to: c.aliceAci, contact: SharedContactInfo(givenName: "Nobody"))
            }
        }
    }
}
