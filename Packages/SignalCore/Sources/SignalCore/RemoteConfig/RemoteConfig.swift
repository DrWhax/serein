// ts/RemoteConfig.dom.ts: GET /v2/config (ETag in `remoteConfigHash`, 304 when unchanged),
// stored as upstream's `remoteConfig` item: name → { name, enabled, value?, enabledAt? }.
// A value of "false" (or none) means disabled.

import Foundation
import GRDB

public enum RemoteConfig {
    public struct Value: Codable, Equatable, Sendable {
        public var name: String
        public var enabled: Bool
        public var value: String?
        public var enabledAt: Int64?
    }

    struct Response: Decodable { var config: [String: String] }

    /// Fetches the config and stores it; returns the names whose value or enablement changed.
    @discardableResult
    public static func refresh(socket: SocketManager, db: DatabaseWriter, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws
        -> Set<String>
    {
        let oldHash: String? = try await db.read { try Items.get($0, "remoteConfigHash") }
        let response = try await socket.authenticatedResponse("GET", "/v2/config", headers: oldHash.map { ["if-none-match": $0] } ?? [:])
        if response.status == 304 { return [] }
        guard (200..<300).contains(response.status) else {
            throw ChatRequestError.http(status: response.status, message: response.message, body: response.body)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: response.body)
        let hash = response.headers["etag"]
        return try await db.write { db in
            let old: [String: Value] = try Items.get(db, "remoteConfig") ?? [:]
            var next: [String: Value] = [:]
            var changed = Set<String>()
            for (name, raw) in decoded.config {
                let enabled = raw.lowercased() != "false"
                let previous = old[name]
                let value = Value(name: name, enabled: enabled, value: enabled ? raw : nil,
                                  enabledAt: previous?.enabled == true && enabled ? now : previous?.enabledAt)
                if previous?.enabled != enabled || previous?.value != value.value { changed.insert(name) }
                next[name] = value
            }
            for name in old.keys where next[name] == nil { changed.insert(name) }
            try Items.set(db, "remoteConfig", next)
            if let hash { try Items.set(db, "remoteConfigHash", hash) }
            return changed
        }
    }

    public static func value(_ db: Database, _ name: String) throws -> String? {
        let config: [String: Value] = try Items.get(db, "remoteConfig") ?? [:]
        return config[name]?.value
    }

    public static func isEnabled(_ db: Database, _ name: String) throws -> Bool {
        let config: [String: Value] = try Items.get(db, "remoteConfig") ?? [:]
        return config[name]?.enabled ?? false
    }

    /// Whether the server's config mentions `name` at all.
    public static func isKnown(_ db: Database, _ name: String) throws -> Bool {
        let config: [String: Value] = try Items.get(db, "remoteConfig") ?? [:]
        return config[name] != nil
    }

    public static func int(_ db: Database, _ name: String) throws -> Int? { try value(db, name).flatMap { Int($0) } }

    /// `isFeaturedEnabledSelector` for a production build (`_isFeatureEnabledInner`): on for an
    /// internal user, or when the server's `prodKey` value is a version at most `version`. A
    /// missing or unparsable value is off.
    public static func isFeatureEnabled(_ db: Database, prodKey: String, version: String) throws -> Bool {
        if try isEnabled(db, "desktop.internalUser") { return true }
        guard let ours = Version(version), let minimum = try value(db, prodKey).flatMap(Version.init) else { return false }
        return ours >= minimum
    }

    /// A semver `major.minor.patch` (prerelease and build suffixes are not compared: production
    /// values have none).
    struct Version: Comparable {
        let parts: [Int]
        init?(_ s: String) {
            let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            let p = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard p.count == 3, p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            parts = p.map { $0! }
        }
        static func < (a: Version, b: Version) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    }
}
