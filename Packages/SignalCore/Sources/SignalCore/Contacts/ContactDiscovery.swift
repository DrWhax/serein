// Contact discovery through CDSI (Desktop ts/textsecure/cds/CDSI.node.ts via
// libsignal-net): credentials from GET v2/directory/auth, then Net.cdsiLookup over an
// attested (SGX) connection. Known ACIs are sent with their access keys so the
// service can return them for e164s that hide their number. Results are merged into
// the private conversations (e164 ↔ ACI/PNI).

import Foundation
import GRDB
import LibSignalClient

public struct CdsiEntry: Sendable, Equatable {
    public var e164: String     // "+<digits>"
    public var aci: String?     // untagged lowercase UUID
    public var pni: String?     // "PNI:<uuid>"
    public init(e164: String, aci: String?, pni: String?) {
        self.e164 = e164
        self.aci = aci
        self.pni = pni
    }
}

public struct CdsiQuery: Sendable {
    public var e164s: [String]
    public var acisAndAccessKeys: [AciAndAccessKey]
}

public final class ContactDiscovery: Sendable {
    public typealias AuthProvider = @Sendable () async throws -> Auth
    public typealias Lookup = @Sendable (Auth, CdsiQuery) async throws -> [CdsiEntry]

    let database: SignalDatabase
    let auth: AuthProvider
    let lookup: Lookup

    /// Production wiring: credentials from GET v2/directory/auth, lookup through `Net.cdsiLookup`.
    public convenience init(net: Net, database: SignalDatabase, socket: SocketManager) {
        self.init(database: database, auth: Self.directoryAuth(socket), lookup: Self.netLookup(net))
    }

    public init(database: SignalDatabase, auth: @escaping AuthProvider, lookup: @escaping Lookup) {
        self.database = database
        self.auth = auth
        self.lookup = lookup
    }

    public static func directoryAuth(_ socket: SocketManager) -> AuthProvider {
        {
            struct AuthResponse: Decodable { var username: String; var password: String }
            let a = try JSONDecoder().decode(AuthResponse.self, from: try await socket.authenticatedRequest("GET", "/v2/directory/auth"))
            return Auth(username: a.username, password: a.password)
        }
    }

    public static func netLookup(_ net: Net) -> Lookup {
        { auth, query in
            let request = try CdsiLookupRequest(e164s: query.e164s, prevE164s: [], acisAndAccessKeys: query.acisAndAccessKeys, token: nil)
            let response = try await net.cdsiLookup(auth: auth, request: request).complete()
            return response.entries.map { e in
                CdsiEntry(e164: "+\(e.e164)", aci: e.aci.map { $0.serviceIdString.lowercased() }, pni: e.pni?.serviceIdString)
            }
        }
    }

    /// Looks up `e164s` (E.164 strings with "+"), merges the results, and returns them.
    @discardableResult
    public func lookup(e164s: [String]) async throws -> [CdsiEntry] {
        let valid = e164s.filter(Self.isE164)
        guard !valid.isEmpty else { return [] }
        let query = CdsiQuery(e164s: valid, acisAndAccessKeys: try await database.pool.read { db in try Self.knownAccessKeys(db) })
        let entries = try await lookup(try await auth(), query)
        try await database.pool.write { db in try Self.apply(db, entries) }
        return entries
    }

    static func isE164(_ s: String) -> Bool {
        s.hasPrefix("+") && (8...16).contains(s.count) && s.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// ACIs whose profile key we know, with the derived access keys.
    static func knownAccessKeys(_ db: Database) throws -> [AciAndAccessKey] {
        let rows = try Row.fetchAll(db, sql: "SELECT serviceId, json ->> '$.profileKey' AS pk FROM conversations WHERE type = 'private' AND pk IS NOT NULL")
        return rows.compactMap { row in
            guard let s: String = row["serviceId"], let aci = try? Aci.parseFrom(serviceIdString: s),
                  let pk = (row["pk"] as String?).flatMap({ Data(base64Encoded: $0) }), let key = try? ProfileKey(contents: pk)
            else { return nil }
            return AciAndAccessKey(aci: aci, accessKey: key.deriveAccessKey())
        }
    }

    /// Merges CDSI results: the conversation is keyed by ACI when known, else by PNI.
    static func apply(_ db: Database, _ entries: [CdsiEntry]) throws {
        for e in entries {
            guard let serviceId = e.aci ?? e.pni else { continue }
            // An e164-only conversation created earlier is adopted by the service id.
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND e164 = ? AND serviceId IS NULL",
                                                  arguments: [e.e164]) {
                try db.execute(sql: "UPDATE conversations SET serviceId = ? WHERE id = ?", arguments: [serviceId, existing])
                try MessageStore.updateConversationJSON(db, conversationId: existing) { $0["serviceId"] = serviceId }
            }
            let conversationId = try MessageStore.privateConversation(db, serviceId: serviceId)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["e164"] = e.e164
                if let pni = e.pni { json["pni"] = pni }
                json["discoveredUnregisteredAt"] = nil
            }
            try db.execute(sql: "UPDATE conversations SET e164 = ? WHERE id = ?", arguments: [e.e164, conversationId])
        }
    }
}
