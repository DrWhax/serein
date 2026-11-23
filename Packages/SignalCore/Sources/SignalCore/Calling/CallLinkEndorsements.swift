import Foundation
import LibSignalClient

enum CallLinkSendError: Error { case invalidEndorsements }

/// One call-link client's SFU-issued endorsements. Only a verified epoch is eligible for sending.
struct CallLinkEndorsements {
    let params: CallLinkSecretParams
    let server: ServerPublicParams
    private(set) var expiration: Date?
    private var byRecipient: [Data: Data] = [:]
    private var valid = false

    init(params: CallLinkSecretParams, server: ServerPublicParams) {
        self.params = params
        self.server = server
    }

    mutating func clear() {
        expiration = nil
        byRecipient.removeAll()
        valid = false
    }

    mutating func receive(_ bytes: Data?, members: [Data], now: Date = Date()) {
        do {
            guard UInt64(exactly: now.timeIntervalSince1970.rounded(.down)) != nil, let bytes,
                  bytes.count <= 512 * 1024, (1...4096).contains(members.count),
                  Set(members).count == members.count else { throw CallLinkSendError.invalidEndorsements }
            let response = try GroupSendEndorsementsResponse(contents: bytes)
            let date = response.expiration
            if let expiration, date < expiration { return }
            guard date > now else { throw CallLinkSendError.invalidEndorsements }
            let ciphertexts = try members.map { try UuidCiphertext(contents: $0) }
            // The bridge needs an excluded member for its optional combined endorsement. An
            // incremental SFU response may omit us. We use only its verified individual proofs.
            let checked = try response.receive(groupMembers: ciphertexts, localUser: ciphertexts[0], now: now, serverParams: server)
            var additions: [Data: Data] = [:]
            for (cipher, endorsement) in zip(ciphertexts, checked.endorsements) {
                let aci = try params.decrypt(cipher).serviceIdBinary
                additions[aci] = endorsement.serialize()
            }
            guard additions.count == members.count else { throw CallLinkSendError.invalidEndorsements }
            if expiration != date { byRecipient.removeAll() }
            byRecipient.merge(additions) { _, new in new }
            guard byRecipient.count <= 4096 else { clear(); return }
            expiration = date
            valid = true
        } catch {
            valid = false
        }
    }

    func endorsements(for recipients: [Data], now: Date = Date()) -> (Date, [Data])? {
        guard valid, let expiration, expiration > now, !recipients.isEmpty, Set(recipients).count == recipients.count else { return nil }
        let endorsements = recipients.compactMap { byRecipient[$0] }
        return endorsements.count == recipients.count ? (expiration, endorsements) : nil
    }

    func token(for endorsements: [Data], expiration: Date, now: Date = Date()) throws -> Data {
        guard expiration > now, UInt64(exactly: expiration.timeIntervalSince1970.rounded(.down)) != nil, (1...4096).contains(endorsements.count) else {
            throw CallLinkSendError.invalidEndorsements
        }
        let individual = try endorsements.map { try GroupSendEndorsement(contents: $0) }
        return try GroupSendEndorsement.combine(individual).toToken(callLinkParams: params).toFullToken(expiration: expiration).serialize()
    }
}
