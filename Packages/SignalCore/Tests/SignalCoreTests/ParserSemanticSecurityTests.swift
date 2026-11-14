import Foundation
import GRDB
import LibSignalClient
import MessageParsing
import SignalProtos
import Testing
@testable import SignalCore

@Suite struct ParserSemanticSecurityTests {
    @Test func oversizedReceiptTimestampIsRejectedBeforeDatabaseConversion() throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let account = Account(aci: UUID().uuidString.lowercased(), pni: nil, number: "+14155550100", deviceId: 2, password: "pw", deviceName: "test",
            aciIdentity: .generate(), pniIdentity: nil, aciRegistrationId: 1, pniRegistrationId: nil, profileKey: nil, masterKey: nil,
            accountEntropyPool: nil, readReceipts: false)
        let receiver = MessageReceiver(account: account, database: database, trustRoots: [], parser: InProcessMessageParser())
        var receipt = Signalservice_ReceiptMessage(); receipt.type = .delivery; receipt.timestamp = [UInt64.max]
        var content = Signalservice_Content(); content.receiptMessage = receipt
        let decrypted = MessageReceiver.Decrypted(sender: UUID().uuidString.lowercased(), senderDevice: 1, content: content, sealed: true, groupId: nil)
        try database.pool.write { db in
            #expect(throws: ReceiveError.self) { try receiver.dispatch(decrypted, envelope: Signalservice_Envelope(), db) }
        }
    }
    @Test func nestedTimestampsAreCheckedButIdentifiersKeepTheirRange() throws {
        var quote = Signalservice_DataMessage.Quote(); quote.id = UInt64.max
        var data = Signalservice_DataMessage(); data.timestamp = 1; data.quote = quote
        var content = Signalservice_Content(); content.dataMessage = data
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(content) }
        var edit = Signalservice_EditMessage(); edit.targetSentTimestamp = UInt64.max
        content = Signalservice_Content(); content.editMessage = edit
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(content) }
        var offer = Signalservice_CallMessage.Offer(); offer.id = UInt64.max
        var call = Signalservice_CallMessage(); call.offer = offer
        content = Signalservice_Content(); content.callMessage = call
        try InboundTimestamps.validate(content)
        var attachment = Signalservice_AttachmentPointer(); attachment.cdnID = UInt64.max
        try InboundTimestamps.validate(attachment)
        attachment.uploadTimestamp = UInt64.max
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(attachment) }
        try InboundTimestamps.check(InboundTimestamps.maximum)
        #expect(throws: ReceiveError.self) { try InboundTimestamps.check(InboundTimestamps.maximum + 1) }
    }

    @Test func syncAndEnvelopeTimestampsAreChecked() throws {
        var read = Signalservice_SyncMessage.Read(); read.timestamp = UInt64.max
        var sync = Signalservice_SyncMessage(); sync.read = [read]
        var content = Signalservice_Content(); content.syncMessage = sync
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(content) }
        var envelope = Signalservice_Envelope(); envelope.clientTimestamp = UInt64.max
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(envelope) }
        envelope.clientTimestamp = 1; envelope.serverTimestamp = UInt64.max
        #expect(throws: ReceiveError.self) { try InboundTimestamps.validate(envelope) }
    }

}
