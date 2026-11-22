import Foundation
import LibSignalClient
import SignalProtos

extension GroupSender {
    /// A call link has no persistent Signal group or sender-key generation. Distribute a
    /// fresh key for this signaling payload and address the sealed envelope to exactly the
    /// devices that received its distribution. Reusing the per-room distribution ID keeps
    /// one bounded sender-key record per sender and room on receiving devices.
    func sendCallLink(_ payload: OutgoingPayload, recipients: [String], token: Data, expiration: Date, distributionId: UUID,
                      scope: @escaping @Sendable () throws -> Void) async throws -> Set<String> {
        guard !recipients.isEmpty, recipients.count == Set(recipients).count, !recipients.contains(account.aci), expiration > Date() else {
            throw CallLinkSendError.invalidEndorsements
        }
        try scope()
        let certificate = try await sender.certificates.current()
        let proto = try payload.content.serializedBytes() as Data
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        let (distributionBytes, envelope) = try Self.callLinkEnvelope(plaintext: MessageSender.pad(proto), local: local,
                                                                     certificate: certificate, hint: payload.contentHint, distributionId: distributionId)
        var content = Signalservice_Content()
        content.senderKeyDistributionMessage = distributionBytes
        let distribution = OutgoingPayload(content: content, timestamp: payload.timestamp, contentHint: .implicit, urgent: payload.urgent)
        var devices: [String: [UInt32]] = [:]
        for id in recipients {
            let result = try await sender.send(distribution, to: id, logged: false, scope: scope)
            guard !result.devices.isEmpty else { throw CallingError.noRecipient }
            devices[id] = result.devices
        }
        let targets = devices
        let (sealed, identities) = try await database.pool.read { db -> (Data, [String: Data]) in
            let ctx = DatabaseStoreContext(db)
            var identities: [String: Data] = [:]
            var addresses: [ProtocolAddress] = []
            for id in recipients {
                guard let key = try ProtocolStore.identityRow(db, serviceId: id)?.key,
                      try !ProtocolStore.needsApproval(db, serviceId: id) else { throw SendError.untrustedIdentities([id]) }
                identities[id] = key
                addresses += try (targets[id] ?? []).map { try ProtocolAddress(name: id, deviceId: $0) }
            }
            let message = try UnidentifiedSenderMessageContent(bytes: envelope)
            let sealed = try sealedSenderMultiRecipientEncrypt(message, for: addresses, identityStore: sender.store, sessionStore: sender.store, context: ctx)
            return (sealed, identities)
        }
        let checks = recipients.map { sender.authorization(to: $0, groupId: Data(), messageIds: [], encryptedIdentity: identities[$0]) }
        let gone = try await socket.sendMultiRecipient(sealed, timestamp: payload.timestamp, token: token, online: payload.online, urgent: payload.urgent) {
            for check in checks { try check() }
            guard expiration > Date() else { throw CallLinkSendError.invalidEndorsements }
            try scope()
        }
        return Set(gone.map { $0.serviceIdString.lowercased() })
    }

    static func callLinkEnvelope(plaintext: Data, local: ProtocolAddress, certificate: SenderCertificate,
                                 hint: UnidentifiedSenderMessageContent.ContentHint, distributionId: UUID) throws -> (Data, Data) {
        let store = InMemorySignalProtocolStore()
        let context = NullContext()
        let distribution = try SenderKeyDistributionMessage(from: local, distributionId: distributionId, store: store, context: context)
        let encrypted = try groupEncrypt(plaintext, from: local, distributionId: distributionId, store: store, context: context)
        let envelope = try UnidentifiedSenderMessageContent(encrypted, from: certificate, contentHint: hint, groupId: Data())
        return (distribution.serialize(), envelope.serialize())
    }
}
