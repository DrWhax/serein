// Release notes and remote megaphones (ts/services/releaseNoteAndMegaphoneFetcher.preload.ts,
// ts/services/megaphone.preload.ts, ts/RemoteConfig.dom.ts isCountryPpmCsvBucketEnabled):
// Signal's manifest on updates2.signal.org lists announcements and megaphones. Once a day (and
// on a new version) its ETag is checked and, when it changed, the manifest is read:
//
// - announcements for a Desktop version after the watermark and up to ours become messages
//   from Signal in the Signal chat (title in bold, the body, the note's image);
// - megaphones (banners above the chat list) are saved with their localized text and image,
//   and the ones the manifest dropped are deleted.
//
// Both may target countries ("code:parts per million" with a "*" fallback), bucketed by a hash
// of our ACI. "Our version" is the Desktop version Serein tracks (SignalClient.desktopVersion).
// Serein has no donations: megaphones asking for one are never shown.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import MediaXPCInterface

/// HEAD for an ETag, GET with a size limit: updates2.signal.org (tests stub it).
public protocol ReleaseNotesTransport: Sendable {
    /// The resource's ETag; nil when it does not exist.
    func etag(_ url: URL) async throws -> String?
    func get(_ url: URL, maxBytes: Int) async throws -> Data
}

public enum ReleaseNotesError: Error, Equatable {
    case badStatus(Int)
    case tooLarge
    case missingManifestHash
}

/// The real transport: an ephemeral session (no cookies or cache), as OptionalResources uses
/// for the same host.
public struct URLSessionReleaseNotesTransport: ReleaseNotesTransport {
    let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    public func etag(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 403 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw ReleaseNotesError.badStatus(http.statusCode) }
        return http.value(forHTTPHeaderField: "etag")
    }

    public func get(_ url: URL, maxBytes: Int) async throws -> Data {
        #if os(Linux)
        let request = URLRequest(url: url, timeoutInterval: 60)
        let (bytes, response) = try await LinuxHTTPSession(roots: []).bytes(for: request)
        defer { bytes.cancel() }
        #else
        let (bytes, response) = try await session.bytes(from: url)
        #endif
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ReleaseNotesError.badStatus(http.statusCode) }
        if response.expectedContentLength > Int64(maxBytes) { throw ReleaseNotesError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw ReleaseNotesError.tooLarge }
        }
        return data
    }
}

/// A saved megaphone (`RemoteMegaphoneType`, the `megaphones` table).
public struct RemoteMegaphoneRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var desktopMinVersion: String?
    public var priority: Int
    public var dontShowBeforeEpochMs: Int64
    public var dontShowAfterEpochMs: Int64
    public var showForNumberOfDays: Int
    public var primaryCtaId: String?
    public var secondaryCtaId: String?
    /// `primaryCtaData` / `secondaryCtaData` as JSON (a snooze's `snoozeDurationDays`).
    public var primaryCtaData: String?
    public var secondaryCtaData: String?
    public var conditionalId: String?
    public var title: String
    public var body: String
    public var primaryCtaText: String?
    public var secondaryCtaText: String?
    /// The image, encrypted at rest like an attachment.
    public var image: LocalFile?
    public var localeFetched: String
    public var shownAt: Int64?
    public var snoozedAt: Int64?
    public var snoozeCount: Int
    public var isFinished: Bool
}

public enum Megaphones {
    /// `MegaphoneCtaId`
    static let knownCtaIds: Set<String> = ["donate", "finish", "snooze"]
    static let day: Int64 = 86_400_000
    /// `SNOOZE_DEFAULT_DURATION_DAYS`
    static let defaultSnoozeDays = 3

    public static func all(_ db: Database) throws -> [RemoteMegaphoneRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM megaphones ORDER BY priority DESC, id").map { r in
            RemoteMegaphoneRecord(id: r["id"], desktopMinVersion: r["desktopMinVersion"], priority: r["priority"],
                                  dontShowBeforeEpochMs: r["dontShowBeforeEpochMs"], dontShowAfterEpochMs: r["dontShowAfterEpochMs"],
                                  showForNumberOfDays: r["showForNumberOfDays"], primaryCtaId: r["primaryCtaId"], secondaryCtaId: r["secondaryCtaId"],
                                  primaryCtaData: r["primaryCtaDataJson"], secondaryCtaData: r["secondaryCtaDataJson"], conditionalId: r["conditionalId"],
                                  title: r["title"], body: r["body"], primaryCtaText: r["primaryCtaText"], secondaryCtaText: r["secondaryCtaText"],
                                  image: (r["imagePath"] as String?).flatMap { LocalFile.from(try? MessageStore.jsonObject($0)) },
                                  localeFetched: r["localeFetched"], shownAt: r["shownAt"], snoozedAt: r["snoozedAt"], snoozeCount: r["snoozeCount"],
                                  isFinished: (r["isFinished"] as Int?) == 1)
        }
    }

    /// `getMegaphoneLastSnoozeDurationMs`: the snooze CTA's durations (days), by snooze count.
    static func lastSnoozeDuration(_ m: RemoteMegaphoneRecord) -> Int64 {
        let data = m.primaryCtaId == "snooze" ? m.primaryCtaData : m.secondaryCtaId == "snooze" ? m.secondaryCtaData : nil
        let days = data.flatMap { try? MessageStore.jsonObject($0) }.flatMap { $0["snoozeDurationDays"] as? [NSNumber] }?.map(\.intValue)
        let durations = (days?.isEmpty == false ? days! : [defaultSnoozeDays])
        let index = min(max(m.snoozeCount - 1, 0), durations.count - 1)
        return Int64(durations[index]) * day
    }

    /// `isConditionalActive`; donations are never offered.
    static func isConditionalActive(_ conditionalId: String?, internalUser: Bool) -> Bool {
        switch conditionalId {
        case nil: true
        case "internal_user": internalUser
        default: false      // standard_donate, test, or unknown
        }
    }

    /// `isMegaphoneShowable`, without donation megaphones.
    public static func isShowable(_ m: RemoteMegaphoneRecord, now: Int64, internalUser: Bool) -> Bool {
        guard !m.isFinished, now >= m.dontShowBeforeEpochMs, now <= m.dontShowAfterEpochMs else { return false }
        let ctas = [m.primaryCtaId, m.secondaryCtaId].compactMap { $0 }
        guard ctas.allSatisfy(knownCtaIds.contains), !ctas.contains("donate") else { return false }
        guard isConditionalActive(m.conditionalId, internalUser: internalUser) else { return false }
        if let snoozed = m.snoozedAt, now < snoozed + lastSnoozeDuration(m) { return false }
        return true
    }

    /// `runMegaphoneCheck`: expired megaphones are deleted (with their images); the showable
    /// ones are returned, the first shown first.
    public static func check(_ db: Database, now: Int64, store: AttachmentStore?) throws -> [RemoteMegaphoneRecord] {
        let internalUser = try RemoteConfig.isEnabled(db, "desktop.internalUser")
        var visible: [RemoteMegaphoneRecord] = []
        for m in try all(db) {
            if now > m.dontShowAfterEpochMs {
                try delete(db, m, store: store)
            } else if isShowable(m, now: now, internalUser: internalUser) {
                visible.append(m)
            }
        }
        return visible
    }

    static func delete(_ db: Database, _ m: RemoteMegaphoneRecord, store: AttachmentStore?) throws {
        try db.execute(sql: "DELETE FROM megaphones WHERE id = ?", arguments: [m.id])
        if let path = m.image?.path { try? store?.delete(path) }
    }

    /// `interactWithMegaphone`: finish (never shown again) or snooze (a while, longer each time).
    public static func interact(_ db: Database, id: String, ctaId: String, now: Int64) throws {
        switch ctaId {
        case "finish", "donate": try db.execute(sql: "UPDATE megaphones SET isFinished = 1 WHERE id = ?", arguments: [id])
        case "snooze": try db.execute(sql: "UPDATE megaphones SET snoozedAt = ?, snoozeCount = snoozeCount + 1 WHERE id = ?", arguments: [now, id])
        default: break
        }
    }
}

/// `isCountryPpmCsvBucketEnabled` (ts/RemoteConfig.dom.ts) with upstream's salt.
public enum CountryBucket {
    /// `getBucketValue`: sha256("<salt>." ‖ aci bytes), the first 8 bytes big-endian, mod 1,000,000.
    static func value(aci: String, salt: String) -> Int? {
        guard let bytes = StorageLocal.uuidBytes(aci) else { return nil }
        var input = Data("\(salt).".utf8)
        input.append(bytes)
        let digest = Array(SignalCrypto.sha256(input))
        let n = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Int(n % 1_000_000)
    }

    /// `getCountryCodeValue`: our country's value, else the "*" fallback.
    static func countryValue(_ countryCode: Int?, _ csv: String) -> Int? {
        var wildcard: Int?
        for item in csv.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            if parts[0] == "*" { wildcard = value } else if let countryCode, String(countryCode) == parts[0] { return value }
        }
        return wildcard
    }

    /// No countries: everyone. Otherwise our bucket must be under our country's parts per million.
    public static func matches(_ csv: String?, e164: String?, aci: String?, salt: String) -> Bool {
        guard let csv, !csv.isEmpty else { return true }
        guard let aci, let bucket = value(aci: aci, salt: salt) else { return false }
        // `getCountryCode`: no number falls back to "*"; an unparsable one matches nothing.
        let code: Int?
        if let e164 {
            guard let c = CountryCallingCode.of(e164) else { return false }
            code = c
        } else {
            code = nil
        }
        guard let threshold = countryValue(code, csv) else { return false }
        return bucket < threshold
    }
}

/// The fetcher (`ReleaseNoteAndMegaphoneFetcher`).
public actor ReleaseNotesService {
    static let base = URL(string: "https://updates2.signal.org/")!
    static let manifestPath = "dynamic/release-notes/release-notes-v2.json"
    static let notesPath = "static/release-notes"
    static let salt = "ReleaseNoteAndMegaphoneFetcher"
    static let fetchInterval: Int64 = 86_400_000
    static let errorRetryDelay: Int64 = 3 * 3_600_000
    static let maxJSON = 1 << 20
    static let maxImage = 10 << 20

    let account: Account
    let database: SignalDatabase
    let store: AttachmentStore?
    let media: (any MediaProcessing)?
    let transport: any ReleaseNotesTransport
    let currentVersion: String
    var running = false

    public init(account: Account, database: SignalDatabase, store: AttachmentStore?, media: (any MediaProcessing)?,
                transport: any ReleaseNotesTransport = URLSessionReleaseNotesTransport(), currentVersion: String = SignalClient.desktopVersion) {
        self.account = account
        self.database = database
        self.store = store
        self.media = media
        self.transport = transport
        self.currentVersion = currentVersion
    }

    struct Manifest: Decodable {
        struct Announcement: Decodable {
            var uuid: String
            var countries: String?
            var desktopMinVersion: String?
            var link: String?
            var ctaId: String?
        }
        struct Megaphone: Decodable {
            var uuid: String
            var priority: Int
            var countries: String?
            var desktopMinVersion: String?
            var dontShowBeforeEpochSeconds: Int64
            var dontShowAfterEpochSeconds: Int64
            var showForNumberOfDays: Int
            var conditionalId: String?
            var primaryCtaId: String?
            var primaryCtaData: ManifestJSON?
            var secondaryCtaId: String?
            var secondaryCtaData: ManifestJSON?
        }
        var announcements: [Announcement]
        var megaphones: [Megaphone]
    }

    /// A note's localized text (`releaseNoteSchema`).
    struct Note: Decodable, Sendable {
        struct Range: Decodable, Sendable { var style: String?; var start: Int?; var length: Int? }
        var title: String
        var body: String
        var bodyRanges: [Range]?
        var media: String?
        var mediaContentType: String?
    }

    /// A megaphone's localized text (`megaphoneSchema`).
    struct LocaleMegaphone: Decodable {
        var title: String
        var body: String
        var image: String?
        var primaryCtaText: String?
        var secondaryCtaText: String?
    }

    /// Runs when the stored next time has come, or at once for a new version; then a day later
    /// (three hours after an error). `locales`: ours, our language, then "en" (upstream's order).
    public func runIfDue(locales: [String], now: Int64? = nil) async {
        let now = now ?? MessageStore.now()
        guard !running else { return }
        let (next, lastVersion) = (try? await database.pool.read { db in
            (try Items.get(db, "releaseNotesNextFetchTime", as: Int64.self), try Items.get(db, "releaseNotesLastVersion", as: String.self))
        }) ?? (nil, nil)
        let isNewVersion = lastVersion != currentVersion
        guard isNewVersion || now >= (next ?? 0) else { return }
        running = true
        defer { running = false }
        let delay: Int64
        do {
            try await run(locales: locales, isNewVersion: isNewVersion, now: now)
            delay = Self.fetchInterval
        } catch {
            delay = Self.errorRetryDelay
        }
        let version = currentVersion
        try? await database.pool.write { db in
            try Items.set(db, "releaseNotesNextFetchTime", now + delay)
            try Items.set(db, "releaseNotesLastVersion", version)
        }
    }

    /// `#run`: the manifest when its hash changed (or on a new version).
    func run(locales: [String], isNewVersion: Bool, now: Int64) async throws {
        let version = currentVersion
        let watermark = try await database.pool.write { db -> String in
            if let w = try Items.get(db, "releaseNotesVersionWatermark", as: String.self) { return w }
            try Items.set(db, "releaseNotesVersionWatermark", version)
            return version
        }
        let manifestURL = Self.base.appendingPathComponent(Self.manifestPath)
        guard let hash = try await transport.etag(manifestURL) else { throw ReleaseNotesError.missingManifestHash }
        let previous = try await database.pool.read { try Items.get($0, "releaseNotesPreviousManifestHash", as: String.self) }
        guard hash != previous || isNewVersion else { return }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try await transport.get(manifestURL, maxBytes: Self.maxJSON))

        let megaphones = manifest.megaphones.filter { $0.desktopMinVersion != nil }
        try await deleteUnknownMegaphones(Set(megaphones.map(\.uuid)))
        try await saveNewMegaphones(megaphones, locales: locales, now: now)

        guard let ours = RemoteConfig.Version(version), let mark = RemoteConfig.Version(watermark) else { return }
        let notes = manifest.announcements.filter { n in
            guard let v = n.desktopMinVersion.flatMap(RemoteConfig.Version.init) else { return false }
            return mark < v && v <= ours
        }
        if !notes.isEmpty { try await processReleaseNotes(notes, locales: locales, now: now) }
        try await database.pool.write { try Items.set($0, "releaseNotesPreviousManifestHash", hash) }
    }

    func url(_ uuid: String, _ locale: String) -> URL {
        Self.base.appendingPathComponent(Self.notesPath).appendingPathComponent(uuid).appendingPathComponent("\(locale).json")
    }

    /// The first locale whose JSON exists (an ETag answers whether it does).
    func localized<T: Decodable>(_ uuid: String, locales: [String], as: T.Type) async throws -> (T, String)? {
        for locale in locales {
            guard try await transport.etag(url(uuid, locale)) != nil else { continue }
            let data = try await transport.get(url(uuid, locale), maxBytes: Self.maxJSON)
            if let decoded = try? JSONDecoder().decode(T.self, from: data) { return (decoded, locale) }
        }
        return nil
    }

    /// `getReleaseNoteImageAttachment`: a path on the same host only.
    func image(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base)?.absoluteURL, url.host == Self.base.host, url.scheme == "https" else {
            throw ReleaseNotesError.badStatus(0)
        }
        return try await transport.get(url, maxBytes: Self.maxImage)
    }

    func ourIdentity() async throws -> (e164: String?, aci: String) {
        (account.number, account.aci)
    }

    // MARK: megaphones

    func deleteUnknownMegaphones(_ known: Set<String>) async throws {
        let store = store
        try await database.pool.write { db in
            for m in try Megaphones.all(db) where !known.contains(m.id) { try Megaphones.delete(db, m, store: store) }
        }
    }

    /// `#saveNewMegaphones`: in date, for our country, not saved yet, with text and an image.
    func saveNewMegaphones(_ megaphones: [Manifest.Megaphone], locales: [String], now: Int64) async throws {
        let (e164, aci) = try await ourIdentity()
        for m in megaphones {
            guard now / 1000 <= m.dontShowAfterEpochSeconds, CountryBucket.matches(m.countries, e164: e164, aci: aci, salt: Self.salt) else { continue }
            let uuid = m.uuid
            if try await database.pool.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM megaphones WHERE id = ?)", arguments: [uuid]) }) == true {
                continue
            }
            guard let (detail, locale) = try? await localized(m.uuid, locales: locales, as: LocaleMegaphone.self), let imagePath = detail.image,
                  let data = try? await image(imagePath), let store else { continue }
            let saved = try store.storeLocally(data)
            let file = try MessageStore.jsonString(["path": saved.path, "localKey": saved.localKey.base64EncodedString(), "size": data.count])
            let row: [(any DatabaseValueConvertible)?] = [
                m.uuid, m.desktopMinVersion, m.priority, m.dontShowBeforeEpochSeconds * 1000, m.dontShowAfterEpochSeconds * 1000, m.showForNumberOfDays,
                m.primaryCtaId, m.secondaryCtaId, m.primaryCtaData?.jsonString, m.secondaryCtaData?.jsonString, m.conditionalId, detail.title, detail.body,
                detail.primaryCtaText, detail.secondaryCtaText, file, locale,
            ]
            let arguments = StatementArguments(row)
            try await database.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO megaphones (id, desktopMinVersion, priority, dontShowBeforeEpochMs, dontShowAfterEpochMs, showForNumberOfDays,
                                            primaryCtaId, secondaryCtaId, primaryCtaDataJson, secondaryCtaDataJson, conditionalId, title, body,
                                            primaryCtaText, secondaryCtaText, imagePath, localeFetched, shownAt, snoozedAt, snoozeCount, isFinished)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 0, 0)
                    """, arguments: arguments)
            }
        }
    }

    // MARK: release notes

    /// `#processReleaseNotes`: the notes as messages from Signal, oldest version first; the
    /// watermark moves to the newest (also when the Signal chat is blocked and nothing is added).
    func processReleaseNotes(_ notes: [Manifest.Announcement], locales: [String], now: Int64) async throws {
        let sorted = notes.sorted { RemoteConfig.Version($0.desktopMinVersion ?? "0.0.0")! < RemoteConfig.Version($1.desktopMinVersion ?? "0.0.0")! }
        guard let newest = sorted.last?.desktopMinVersion else { return }
        let signal = StorageLocal.signalAci
        let blocked = try await database.pool.write { db -> Bool in
            try ReleaseNotesChat.ensure(db)
            return try BlockedList.serviceIds.blockedAt(db, signal).blocked
        }
        if blocked {
            try await database.pool.write { try Items.set($0, "releaseNotesVersionWatermark", newest) }
            return
        }
        let (e164, aci) = try await ourIdentity()
        var prepared: [(Note, MessageAttachment?)] = []
        for note in sorted where CountryBucket.matches(note.countries, e164: e164, aci: aci, salt: Self.salt) {
            guard let (detail, _) = try await localized(note.uuid, locales: locales, as: Note.self) else { continue }
            var attachment: MessageAttachment?
            if let media = detail.media, let store {
                let data = try await image(media)
                let type = detail.mediaContentType ?? Self.sniff(data)
                var a = MessageAttachment(contentType: type, size: data.count)
                let stored = try store.storeLocally(data)
                a.path = stored.path
                a.localKey = stored.localKey.base64EncodedString()
                a.plaintextHash = stored.plaintextHash
                a.version = 2
                if type == "video/mp4" { a.flags = 8 }    // AttachmentPointer.Flags.GIF
                if let info = try? await self.media?.imageInfo(data).validated() {
                    a.width = info.width
                    a.height = info.height
                    a.blurHash = info.blurHash
                }
                attachment = a
            }
            prepared.append((detail, attachment))
        }
        let ready = prepared
        try await database.pool.write { db in
            let conversationId = try ReleaseNotesChat.ensure(db)
            for (index, (note, attachment)) in ready.enumerated() {
                let sentAt = now + Int64(index)
                // The title in bold, a blank line, the body with its styles moved after it.
                let body = note.title + "\n\n" + note.body
                let offset = (note.title as NSString).length + 2
                var ranges: [[String: Any]] = [["start": 0, "length": (note.title as NSString).length, "style": 1]]
                for r in note.bodyRanges ?? [] {
                    guard let start = r.start, let length = r.length, let style = r.style.flatMap(Self.styleNumber) else { continue }
                    ranges.append(["start": start + offset, "length": length, "style": style])
                }
                let id = try MessageStore.insert(db, .init(conversationId: conversationId, type: "incoming", body: body, sentAt: UInt64(sentAt), source: signal,
                                                           sourceDevice: 1, serverGuid: nil, serverTimestamp: UInt64(sentAt), unidentified: false,
                                                           extra: ["bodyRanges": ranges]))
                if let attachment {
                    let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [id]) ?? sentAt
                    try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversationId, sentAt: sentAt,
                                                  receivedAt: receivedAt, messageType: "incoming", attachment)
                    try MessageAttachments.updateMessageFlags(db, messageId: id)
                }
            }
            try Items.set(db, "releaseNotesVersionWatermark", newest)
            if !ready.isEmpty {
                // `canConversationBeUnarchived`: it comes back to the inbox.
                try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["isArchived"] = false }
            }
        }
    }

    /// `BodyRange.Style` by name.
    static func styleNumber(_ name: String) -> Int? {
        ["BOLD": 1, "ITALIC": 2, "SPOILER": 3, "STRIKETHROUGH": 4, "MONOSPACE": 5][name.uppercased()]
    }

    static func sniff(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "application/octet-stream"
    }
}

/// The Signal release-notes chat (`getOrCreateSignalConversation`): named Signal, muted for
/// good, read-only (the UI's `isSignalConversation`).
public enum ReleaseNotesChat {
    @discardableResult
    static func ensure(_ db: Database) throws -> String {
        let id = try MessageStore.privateConversation(db, serviceId: StorageLocal.signalAci)
        try MessageStore.updateConversationJSON(db, conversationId: id) { json in
            if json["profileName"] == nil { json["profileName"] = "Signal" }
            json["muteExpiresAt"] = Int64.max / 2
            json["profileSharing"] = true
        }
        try db.execute(sql: "UPDATE conversations SET profileName = coalesce(profileName, 'Signal'), profileFullName = coalesce(profileFullName, 'Signal') WHERE id = ?",
                       arguments: [id])
        return id
    }

    public static func isSignalChat(serviceId: String?) -> Bool { serviceId == StorageLocal.signalAci }
}

/// A JSON value kept as it came (a CTA's data).
struct ManifestJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: ManifestJSON].self) { value = d.mapValues(\.value) }
        else if let a = try? c.decode([ManifestJSON].self) { value = a.map(\.value) }
        else if let n = try? c.decode(Double.self) { value = n }
        else if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = NSNull() }
    }
    var jsonString: String? {
        guard JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

extension SignalDatabase {
    /// The visible megaphones (`runMegaphoneCheck`), re-checked when they change.
    public func megaphoneUpdates(store: AttachmentStore?) -> AsyncThrowingStream<[RemoteMegaphoneRecord], Error> {
        observe { db in
            try Megaphones.all(db).filter { m in
                (try? Megaphones.isShowable(m, now: MessageStore.now(), internalUser: RemoteConfig.isEnabled(db, "desktop.internalUser"))) ?? false
            }
        }
    }

    /// `interactWithMegaphone`
    public func interactWithMegaphone(id: String, ctaId: String) async throws {
        try await pool.write { try Megaphones.interact($0, id: id, ctaId: ctaId, now: MessageStore.now()) }
    }

    /// `runMegaphoneCheck`'s cleanup: expired megaphones go.
    public func checkMegaphones(store: AttachmentStore?) async throws {
        _ = try await pool.write { try Megaphones.check($0, now: MessageStore.now(), store: store) }
    }
}
