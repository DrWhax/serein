// Call link URLs (upstream ts/util/callLinks linkCallRoute): https://signal.link/call/#key=<the
// root key's consonant base-16 form>, also as sgnl://signal.link/call/#key=…; and adding a
// link someone shared (once the SFU confirms it exists) so it shows in the Calls tab.

import Foundation
import GRDB
import SignalRingRTC

public enum CallLinkURL {
    /// The link to share for a root key.
    public static func url(rootKey: Data) throws -> String {
        "https://signal.link/call/#key=" + (try CallLinkRootKey.fromBytes(rootKey).formatted())
    }

    /// The root key in a call link URL (nil: not a call link, or a malformed key).
    public static func rootKey(from url: URL) -> CallLinkRootKey? {
        guard ["https", "sgnl"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "signal.link",
              url.path == "/call" || url.path == "/call/", let fragment = url.fragment else { return nil }
        let params = Dictionary(fragment.split(separator: "&").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1]).removingPercentEncoding ?? String(kv[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        guard let key = params["key"] else { return nil }
        return try? CallLinkRootKey.parse(key)
    }

    public static func isCallLink(_ url: URL) -> Bool { rootKey(from: url) != nil }
}

extension CallingService {
    /// A call link from a URL: its record (added, with the SFU's state, when new). Throws when
    /// the SFU no longer has it.
    public func addCallLink(rootKey: CallLinkRootKey) async throws -> CallLinkRecord {
        let roomId = try rootKey.deriveRoomId().hexString
        if let known = try await database.pool.read({ try CallLinkStore.get($0, roomId: roomId) }), !known.deleted { return known }
        guard let state = try await readCallLink(rootKey: rootKey) else { throw CallingError.callLinkRequestFailed(status: 404) }
        let record = CallLinkRecord(roomId: roomId, rootKey: rootKey.bytes, adminKey: nil, name: state.name, restrictions: state.restrictions.rawValue,
                                    revoked: state.revoked, expiration: Int64(state.expiration.timeIntervalSince1970 * 1000))
        let now = MessageStore.now()
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM callLinks WHERE roomId = ? AND deleted = 1", arguments: [roomId])
            try CallLinkStore.insert(db, record)
            try CallHistoryStore.save(db, CallLinkStore.placeholderHistory(roomId: roomId, now: now))
        }
        emit(.historyChanged)
        return record
    }
}

extension SignalDatabase {
    public func callLinkUpdates() -> AsyncThrowingStream<[CallLinkRecord], Error> { observe { try CallLinkStore.all($0) } }
}
