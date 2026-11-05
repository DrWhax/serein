// Sender certificates for sealed sender (Desktop SenderCertificateService): fetched
// from GET v1/certificate/delivery, validated against the server trust roots and our
// own identity, cached in `items` (upstream keys senderCertificate /
// senderCertificateNoE164, value {expires, serialized}) and refreshed a day before expiry.

import Foundation
import GRDB
import LibSignalClient

public enum SenderCertificateMode: Sendable {
    case withE164, withoutE164
    var itemKey: String { self == .withE164 ? "senderCertificate" : "senderCertificateNoE164" }
    var query: String { self == .withE164 ? "true" : "false" }
}

public enum SenderCertificateError: Error, Equatable {
    case invalid(String)
}

public final class SenderCertificates: Sendable {
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let trustRoots: [PublicKey]
    static let refreshMargin: UInt64 = 24 * 60 * 60 * 1000

    struct Cached: Codable { var expires: UInt64; var serialized: String }

    public init(account: Account, database: SignalDatabase, socket: SocketManager, trustRoots: [PublicKey]) {
        self.account = account
        self.database = database
        self.socket = socket
        self.trustRoots = trustRoots
    }

    public func current(_ mode: SenderCertificateMode = .withoutE164, now time: UInt64? = nil) async throws -> SenderCertificate {
        let now = time ?? UInt64(MessageStore.now())
        if let cached = try await database.pool.read({ db in try Items.get(db, mode.itemKey, as: Cached.self) }),
           cached.expires > now + Self.refreshMargin, let bytes = Data(base64Encoded: cached.serialized),
           let certificate = try? SenderCertificate(bytes), certificate.validate(trustRoots: trustRoots, time: now) {
            return certificate
        }
        return try await refresh(mode, now: now)
    }

    @discardableResult
    public func refresh(_ mode: SenderCertificateMode = .withoutE164, now time: UInt64? = nil) async throws -> SenderCertificate {
        let now = time ?? UInt64(MessageStore.now())
        struct Response: Decodable { var certificate: String }
        let body = try await socket.authenticatedRequest("GET", "/v1/certificate/delivery?includeE164=\(mode.query)")
        guard let bytes = Data(base64Encoded: try JSONDecoder().decode(Response.self, from: body).certificate) else {
            throw SenderCertificateError.invalid("encoding")
        }
        let certificate = try SenderCertificate(bytes)
        guard certificate.validate(trustRoots: trustRoots, time: now) else { throw SenderCertificateError.invalid("signature or expiry") }
        guard certificate.senderUuid.lowercased() == account.aci, certificate.deviceId == account.deviceId else {
            throw SenderCertificateError.invalid("issued for \(certificate.senderUuid).\(certificate.deviceId)")
        }
        guard certificate.publicKey == account.aciIdentity.publicKey else { throw SenderCertificateError.invalid("identity key") }
        try await database.pool.write { db in
            try Items.set(db, mode.itemKey, Cached(expires: certificate.expiration, serialized: bytes.base64EncodedString()))
        }
        return certificate
    }
}
