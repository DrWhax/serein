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
import SignalProtos
import SwiftProtobuf

public enum ContactSyncError: Error, Equatable {
    case truncated(offset: Int)
    case varintTooLong(offset: Int)
    case tooManyContacts
    case noCDN(Int)
}

public final class ContactSync: Sendable {
    public static let queueType = "contact sync"
    public struct Job: Codable, Sendable {
        public var pointer: Data    // serialized AttachmentPointer
        public var complete: Bool
    }

    static let maxContacts = 50_000
    static let maxBlobBytes = 64 << 20

    let database: SignalDatabase
    let http: HTTPClient
    let endpoints: ServiceEndpoints

    public init(database: SignalDatabase, http: HTTPClient, endpoints: ServiceEndpoints) {
        self.database = database
        self.http = http
        self.endpoints = endpoints
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
        let contacts = try Self.parse(plaintext)
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
        return try await client.send("GET", base.appendingPathComponent("attachments").appendingPathComponent(path)).body
    }

    // MARK: grammar

    /// Parses the length-delimited ContactDetails stream (avatars are skipped).
    public static func parse(_ data: Data) throws -> [Signalservice_ContactDetails] {
        let bytes = [UInt8](data)
        var offset = 0
        var out: [Signalservice_ContactDetails] = []
        while offset < bytes.count {
            guard out.count < maxContacts else { throw ContactSyncError.tooManyContacts }
            let length = try readVarint32(bytes, &offset)
            guard length <= bytes.count - offset else { throw ContactSyncError.truncated(offset: offset) }
            let details = try Signalservice_ContactDetails(serializedBytes: Data(bytes[offset..<(offset + length)]))
            offset += length
            if details.hasAvatar, details.avatar.hasLength {
                let avatar = Int(details.avatar.length)
                guard avatar <= bytes.count - offset else { throw ContactSyncError.truncated(offset: offset) }
                offset += avatar
            }
            out.append(details)
        }
        return out
    }

    /// Protobuf base-128 varint, at most 5 bytes, value < 2^32.
    static func readVarint32(_ bytes: [UInt8], _ offset: inout Int) throws -> Int {
        var value: UInt64 = 0
        for i in 0..<5 {
            guard offset < bytes.count else { throw ContactSyncError.truncated(offset: offset) }
            let b = bytes[offset]
            offset += 1
            value |= UInt64(b & 0x7F) << (7 * UInt64(i))
            if b & 0x80 == 0 {
                guard value <= UInt64(UInt32.max) else { throw ContactSyncError.varintTooLong(offset: offset) }
                return Int(value)
            }
        }
        throw ContactSyncError.varintTooLong(offset: offset)
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
