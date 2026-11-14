// Contact sync from the primary device (Desktop ts/textsecure/ContactsParser +
// doContactSync): SyncMessage.Contacts carries an attachment pointer to a blob that,
// once downloaded and decrypted, is a stream of
//
//   contacts  := entry*
//   entry     := varint32(length) ContactDetails[length] avatar[details.avatar.length]?
//
// The framing is parsed with explicit bounds (every length is checked against the
// remaining input before use); each ContactDetails is decoded by SwiftProtobuf.

import Foundation
import GRDB
import LibSignalClient
import MessageParsing
import SignalProtos
import SwiftProtobuf

public enum ContactSyncError: Error, Equatable {
    case noCDN(Int)
}

public final class ContactSync: Sendable {
    public static let queueType = "contact sync"
    public struct Job: Codable, Sendable {
        public var pointer: Data    // serialized AttachmentPointer
        public var complete: Bool
    }

    static let maxBlobBytes = 64 << 20

    let database: SignalDatabase
    let http: HTTPClient
    let endpoints: ServiceEndpoints
    /// The blob's records are parsed outside this process (SignalMessageParser.xpc in the app).
    let parser: any StructuredMessageParser

    public init(database: SignalDatabase, http: HTTPClient, endpoints: ServiceEndpoints, parser: any StructuredMessageParser) {
        self.database = database
        self.http = http
        self.endpoints = endpoints
        self.parser = parser
    }

    public func register(on jobs: JobQueue) async {
        await jobs.register(Self.queueType) { [self] job in
            let j = try job.decode(Job.self)
            _ = try await self.process(try Signalservice_AttachmentPointer(serializedBytes: j.pointer))
        }
    }

    /// Downloads, decrypts and applies a contact-sync blob. Returns the number of contacts applied.
    @discardableResult
    public func process(_ pointer: Signalservice_AttachmentPointer) async throws -> Int {
        let blob = try await download(pointer)
        let plaintext = try AttachmentCipher.decrypt(blob, key: pointer.key, digest: pointer.hasDigest ? pointer.digest : nil,
                                                     size: pointer.hasSize ? Int(pointer.size) : nil)
        let contacts = try Self.parse(plaintext, parser: parser)
        try await database.pool.write { db in try Self.apply(db, contacts) }
        return contacts.count
    }

    func download(_ pointer: Signalservice_AttachmentPointer) async throws -> Data {
        let cdn = pointer.hasCdnNumber ? Int(pointer.cdnNumber) : 0
        guard let base = endpoints.cdnURLs[cdn] else { throw ContactSyncError.noCDN(cdn) }
        let path: String
        switch pointer.attachmentIdentifier {
        case .cdnKey(let key): path = key
        case .cdnID(let id): path = String(id)
        case .none: throw ContactSyncError.noCDN(cdn)
        }
        var client = http
        client.maxResponseBytes = Self.maxBlobBytes
        return try await client.send("GET", try base.cdnAttachment(path)).body
    }

    // MARK: grammar

    /// The length-delimited ContactDetails stream (avatars are skipped), parsed by `parser`
    /// (MessageParsing.ContactStream has the grammar).
    public static func parse(_ data: Data, parser: any StructuredMessageParser = InProcessMessageParser()) throws -> [Signalservice_ContactDetails] {
        try parser.contactDetails(data, source: "contact-sync")
    }

    // MARK: apply

    static func apply(_ db: Database, _ contacts: [Signalservice_ContactDetails]) throws {
        for c in contacts {
            guard let aci = MessageReceiver.serviceIdString(binary: c.hasAciBinary ? c.aciBinary : nil, string: c.hasAci ? c.aci : nil),
                  (try? Aci.parseFrom(serviceIdString: aci)) != nil
            else { continue }
            let conversationId = try MessageStore.privateConversation(db, serviceId: aci)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                if c.hasNumber, !c.number.isEmpty { json["e164"] = c.number }
                if c.hasName { json["name"] = c.name }
                if c.hasExpireTimer {
                    json["expireTimer"] = c.expireTimer
                    if c.hasExpireTimerVersion { json["expireTimerVersion"] = c.expireTimerVersion }
                }
                if c.hasInboxPosition { json["inbox_position"] = c.inboxPosition }
            }
            try db.execute(sql: "UPDATE conversations SET e164 = coalesce(?, e164), name = coalesce(?, name) WHERE id = ?",
                           arguments: [c.hasNumber && !c.number.isEmpty ? c.number : nil, c.hasName ? c.name : nil, conversationId])
        }
    }
}
