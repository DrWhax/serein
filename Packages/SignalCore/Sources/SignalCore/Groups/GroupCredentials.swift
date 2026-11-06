// ts/services/groupCredentialFetcher.preload.ts: daily zkgroup auth credentials (today through
// six days out) from GET /v1/certificate/auth/group, received with our ACI + PNI and kept in the
// `groupCredentials` item as { redemptionTime (ms), credential (base64 AuthCredentialWithPni) }.
// A group request presents today's credential: Basic base64("<publicParams hex>:<presentation hex>").

import Foundation
import GRDB
import LibSignalClient

public struct GroupCredential: Codable, Equatable, Sendable {
    public var redemptionTime: Int64     // ms, midnight UTC
    public var credential: String        // base64
}

public enum GroupCredentialError: Error, Equatable {
    case noCredentialForToday
    case pniMismatch
}

public struct GroupCredentials: Sendable {
    public static let day: Int64 = 86_400_000
    let account: Account
    let socket: SocketManager
    let db: DatabaseWriter
    /// Serialized ServerPublicParams (the zkgroup server key).
    let serverParamsData: Data
    /// Serialized GenericServerPublicParams (call links); without them no call-link
    /// credentials are kept.
    let genericServerParamsData: Data?

    public init(account: Account, socket: SocketManager, db: DatabaseWriter, serverPublicParams: Data, genericServerPublicParams: Data? = nil) {
        self.account = account
        self.socket = socket
        self.db = db
        serverParamsData = serverPublicParams
        genericServerParamsData = genericServerPublicParams
    }

    func genericServerParams() throws -> GenericServerPublicParams {
        guard let d = genericServerParamsData else { throw GroupCredentialError.noCredentialForToday }
        return try GenericServerPublicParams(contents: d)
    }

    func serverParams() throws -> ServerPublicParams { try ServerPublicParams(contents: serverParamsData) }

    static func toDay(_ ms: Int64) -> Int64 { ms / day * day }

    /// `getDatesForRequest`
    static func requestRange(_ stored: [GroupCredential], now: Int64) -> (start: Int64, end: Int64)? {
        let today = toDay(now), sixDaysOut = today + 6 * day
        guard stored.contains(where: { $0.redemptionTime == today }), let last = stored.last, last.redemptionTime >= today else {
            return (today, sixDaysOut)
        }
        if last.redemptionTime >= sixDaysOut { return nil }
        return (last.redemptionTime + day, sixDaysOut)
    }

    struct Response: Decodable {
        struct Item: Decodable { var credential: String; var redemptionTime: Int64 }
        var credentials: [Item]
        var callLinkAuthCredentials: [Item]?
        var pni: String?
    }

    /// `maybeFetchNewCredentials`
    public func refresh(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        let stored: [GroupCredential] = try await db.read { try Items.get($0, "groupCredentials") } ?? []
        let storedCallLinks: [GroupCredential] = try await db.read { try Items.get($0, "callLinkAuthCredentials") } ?? []
        // One request covers both sets (the union of the ranges each needs).
        let ranges = [Self.requestRange(stored, now: now), genericServerParamsData == nil ? nil : Self.requestRange(storedCallLinks, now: now)].compactMap { $0 }
        guard !ranges.isEmpty else { return }
        let range = (start: ranges.map(\.start).min()!, end: ranges.map(\.end).max()!)
        let body = try await socket.authenticatedRequest(
            "GET", "/v1/certificate/auth/group?redemptionStartSeconds=\(range.start / 1000)&redemptionEndSeconds=\(range.end / 1000)&v101=true&zkcCredential=true")
        let response = try JSONDecoder().decode(Response.self, from: body)
        guard let pniString = response.pni ?? account.pni else { throw GroupCredentialError.pniMismatch }
        let aci = try Aci.parseFrom(serviceIdString: account.aci)
        let pni = try Pni.parseFrom(serviceIdString: pniString.hasPrefix("PNI:") ? pniString : "PNI:" + pniString)
        let ops = ClientZkAuthOperations(serverPublicParams: try serverParams())
        let fresh = try response.credentials.sorted { $0.redemptionTime < $1.redemptionTime }.map { item -> GroupCredential in
            guard let bytes = Data(base64Encoded: item.credential) else { throw GroupCredentialError.noCredentialForToday }
            let credential = try ops.receiveAuthCredentialWithPniAsServiceId(aci: aci, pni: pni, redemptionTime: UInt64(item.redemptionTime),
                                                                            authCredentialResponse: AuthCredentialWithPniResponse(contents: bytes))
            return GroupCredential(redemptionTime: item.redemptionTime * 1000, credential: credential.serialize().base64EncodedString())
        }
        // Call-link credentials, received with the generic server params.
        var freshCallLinks: [GroupCredential] = []
        if genericServerParamsData != nil {
            let generic = try genericServerParams()
            freshCallLinks = try (response.callLinkAuthCredentials ?? []).sorted { $0.redemptionTime < $1.redemptionTime }.map { item in
                guard let bytes = Data(base64Encoded: item.credential) else { throw GroupCredentialError.noCredentialForToday }
                let credential = try CallLinkAuthCredentialResponse(contents: bytes)
                    .receive(userId: aci, redemptionTime: Date(timeIntervalSince1970: TimeInterval(item.redemptionTime)), params: generic)
                return GroupCredential(redemptionTime: item.redemptionTime * 1000, credential: credential.serialize().base64EncodedString())
            }
        }
        let today = Self.toDay(now)
        let newCallLinks = freshCallLinks
        try await db.write { db in
            let freshCallLinks = newCallLinks
            let keep = Set(fresh.map(\.redemptionTime))
            try Items.set(db, "groupCredentials", stored.filter { $0.redemptionTime >= today && !keep.contains($0.redemptionTime) } + fresh)
            if !freshCallLinks.isEmpty {
                let keepCL = Set(freshCallLinks.map(\.redemptionTime))
                try Items.set(db, "callLinkAuthCredentials",
                              storedCallLinks.filter { $0.redemptionTime >= today && !keepCL.contains($0.redemptionTime) } + freshCallLinks)
            }
        }
    }

    /// Today's credential (fetching if missing).
    func today(now: Int64) async throws -> AuthCredentialWithPni {
        func find() async throws -> GroupCredential? {
            let stored: [GroupCredential] = try await db.read { try Items.get($0, "groupCredentials") } ?? []
            return stored.first { $0.redemptionTime == Self.toDay(now) }
        }
        var c = try await find()
        if c == nil {
            try await refresh(now: now)
            c = try await find()
        }
        guard let c, let bytes = Data(base64Encoded: c.credential) else { throw GroupCredentialError.noCredentialForToday }
        return try AuthCredentialWithPni(contents: bytes)
    }

    /// The `Authorization` header for a group request (`generateGroupAuth`).
    public func authorization(for secretParams: GroupSecretParams, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> String {
        let credential = try await today(now: now)
        let presentation = try ClientZkAuthOperations(serverPublicParams: try serverParams())
            .createAuthCredentialPresentation(groupSecretParams: secretParams, authCredential: credential)
        let user = try secretParams.getPublicParams().serialize().hexString
        return HTTPClient.basicAuth(user, presentation.serialize().hexString)
    }
}

// MARK: call links (ts/util/callLinks/zkgroup.preload.ts, CallingClass.createCallLink)

extension GroupCredentials {
    /// `getCallLinkAuthCredentialPresentation`: today's call-link auth credential, presented
    /// for the link's secret params.
    public func callLinkAuthPresentation(rootKey: Data, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> Data {
        func find() async throws -> GroupCredential? {
            let stored: [GroupCredential] = try await db.read { try Items.get($0, "callLinkAuthCredentials") } ?? []
            return stored.first { $0.redemptionTime == Self.toDay(now) }
        }
        var c = try await find()
        if c == nil {
            try await refresh(now: now)
            c = try await find()
        }
        guard let c, let bytes = Data(base64Encoded: c.credential) else { throw GroupCredentialError.noCredentialForToday }
        let credential = try CallLinkAuthCredential(contents: bytes)
        let aci = try Aci.parseFrom(serviceIdString: account.aci)
        return credential.present(userId: aci, redemptionTime: Date(timeIntervalSince1970: TimeInterval(c.redemptionTime / 1000)),
                                  serverParams: try genericServerParams(), callLinkParams: CallLinkSecretParams.deriveFromRootKey(rootKey)).serialize()
    }

    /// `callLinkCreateAuth` + receive + present: the presentation that authorises creating
    /// the room `roomId`.
    public func createCallLinkPresentation(roomId: Data, rootKey: Data) async throws -> Data {
        let context = CreateCallLinkCredentialRequestContext.forRoomId(roomId)
        struct Body: Encodable { var createCallLinkCredentialRequest: String }
        struct Reply: Decodable { var credential: String }
        let body = try JSONEncoder().encode(Body(createCallLinkCredentialRequest: context.getRequest().serialize().base64EncodedString()))
        let reply = try JSONDecoder().decode(Reply.self, from: try await socket.authenticatedRequest("POST", "/v1/call-link/create-auth", json: body))
        guard let bytes = Data(base64Encoded: reply.credential) else { throw GroupCredentialError.noCredentialForToday }
        let aci = try Aci.parseFrom(serviceIdString: account.aci)
        let generic = try genericServerParams()
        let credential = try context.receive(try CreateCallLinkCredentialResponse(contents: bytes), userId: aci, params: generic)
        return credential.present(roomId: roomId, userId: aci, serverParams: generic, callLinkParams: CallLinkSecretParams.deriveFromRootKey(rootKey)).serialize()
    }
}
