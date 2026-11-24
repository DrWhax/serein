// Server alerts (handleServerAlerts), country buckets (RemoteConfig_test's vectors), megaphone
// rules (megaphone.preload.ts) and the release-note fetch (releaseNoteAndMegaphoneFetcher),
// against a stubbed updates2.signal.org.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct AnnouncementTests {
    static let day: Int64 = 86_400_000

    @Test func serverAlerts() throws {
        #expect(ServerAlerts.parse(["Idle-Primary-Device", "critical-idle-primary-device, bogus"]) == [.idlePrimaryDevice, .criticalIdlePrimaryDevice])
        let (db, _) = try LinkedClient.temporaryDatabase()
        try db.pool.write { try ServerAlerts.received($0, [.idlePrimaryDevice], now: 1_000) }
        try db.pool.write { try ServerAlerts.received($0, [.idlePrimaryDevice], now: 9_000) }      // seen before: kept
        var alerts = try db.pool.read { try ServerAlerts.current($0) }
        #expect(alerts == [.idlePrimaryDevice: ServerAlertInfo(firstReceivedAt: 1_000)])
        #expect(ServerAlerts.toShow(alerts, now: 2_000) == .idlePrimaryDevice)
        try db.pool.write { try ServerAlerts.dismissIdleBanner($0, now: 2_000) }
        alerts = try db.pool.read { try ServerAlerts.current($0) }
        #expect(ServerAlerts.toShow(alerts, now: 2_000 + 6 * Self.day) == nil)              // dismissed for a week
        #expect(ServerAlerts.toShow(alerts, now: 2_000 + 7 * Self.day) == .idlePrimaryDevice)

        // Critical: shown over everything; its dialog three days in, then daily after a close.
        try db.pool.write { try ServerAlerts.received($0, [.criticalIdlePrimaryDevice], now: 10_000) }
        alerts = try db.pool.read { try ServerAlerts.current($0) }
        #expect(alerts[.idlePrimaryDevice] == nil)                                            // no longer sent: dropped
        #expect(ServerAlerts.toShow(alerts, now: 10_000) == .criticalIdlePrimaryDevice)
        #expect(ServerAlerts.criticalModalDue(alerts, now: 10_000) == 10_000 + 3 * Self.day)
        #expect(ServerAlerts.criticalModalDue(alerts, now: 10_000 + 4 * Self.day) == 10_000 + 4 * Self.day)
        try db.pool.write { try ServerAlerts.dismissCriticalModal($0, now: 10_000 + 4 * Self.day) }
        alerts = try db.pool.read { try ServerAlerts.current($0) }
        #expect(ServerAlerts.criticalModalDue(alerts, now: 10_000 + 4 * Self.day + 1) == 10_000 + 5 * Self.day)
        try db.pool.write { try ServerAlerts.received($0, [], now: 20_000) }
        #expect(try db.pool.read { try ServerAlerts.current($0) }.isEmpty)
    }

    /// ts/test-node/RemoteConfig_test.dom.ts
    @Test func countryBuckets() {
        let aci = "95b9729c-51ea-4ddb-b516-652befe78062"
        #expect(CountryBucket.value(aci: aci, salt: "research.megaphone.1") == 222_732)
        #expect(CountryBucket.value(aci: aci, salt: "desktop.internalUser") == 376_321)
        #expect(CountryBucket.matches("*:1000000", e164: "+12125550000", aci: aci, salt: "desktop.internalUser"))
        #expect(CountryBucket.matches("1:700000", e164: "+12125550000", aci: aci, salt: "desktop.internalUser"))
        #expect(!CountryBucket.matches("1:300000", e164: "+12125550000", aci: aci, salt: "desktop.internalUser"))
        #expect(CountryBucket.countryValue(nil, "*:56,1:74") == 56 && CountryBucket.countryValue(nil, "1:74,2:56") == nil)
        #expect(CountryBucket.countryValue(1, "*:56,1:74") == 74)
        #expect(CountryBucket.matches(nil, e164: nil, aci: nil, salt: "x"))                 // no countries: everyone
        #expect(!CountryBucket.matches("*:1000000", e164: "+999", aci: aci, salt: "x"))     // not a number we can place
    }

    static func megaphone(_ id: String, before: Int64 = 0, after: Int64 = 10 * day, primary: String? = "finish", secondary: String? = "snooze",
                          secondaryData: String? = nil, conditional: String? = nil) -> RemoteMegaphoneRecord {
        RemoteMegaphoneRecord(id: id, desktopMinVersion: "8.0.0", priority: 100, dontShowBeforeEpochMs: before, dontShowAfterEpochMs: after,
                              showForNumberOfDays: 30, primaryCtaId: primary, secondaryCtaId: secondary, primaryCtaData: nil, secondaryCtaData: secondaryData,
                              conditionalId: conditional, title: "t", body: "b", primaryCtaText: nil, secondaryCtaText: nil, image: nil,
                              localeFetched: "en", shownAt: nil, snoozedAt: nil, snoozeCount: 0, isFinished: false)
    }

    @Test func megaphoneRules() {
        let now = 5 * Self.day
        #expect(Megaphones.isShowable(Self.megaphone("a"), now: now, internalUser: false))
        #expect(!Megaphones.isShowable(Self.megaphone("a", before: 6 * Self.day), now: now, internalUser: false))   // not yet
        #expect(!Megaphones.isShowable(Self.megaphone("a", after: 4 * Self.day), now: now, internalUser: false))    // over
        #expect(!Megaphones.isShowable(Self.megaphone("a", primary: "donate"), now: now, internalUser: false))      // no donations
        #expect(!Megaphones.isShowable(Self.megaphone("a", primary: "upgrade"), now: now, internalUser: false))     // unknown CTA
        #expect(!Megaphones.isShowable(Self.megaphone("a", conditional: "standard_donate"), now: now, internalUser: false))
        #expect(!Megaphones.isShowable(Self.megaphone("a", conditional: "internal_user"), now: now, internalUser: false))
        #expect(Megaphones.isShowable(Self.megaphone("a", conditional: "internal_user"), now: now, internalUser: true))
        var finished = Self.megaphone("a")
        finished.isFinished = true
        #expect(!Megaphones.isShowable(finished, now: now, internalUser: false))

        // Snoozing: the CTA's durations by count (default three days).
        var snoozed = Self.megaphone("a", secondaryData: "{\"snoozeDurationDays\":[1,7]}")
        snoozed.snoozedAt = now
        snoozed.snoozeCount = 1
        #expect(!Megaphones.isShowable(snoozed, now: now + Self.day - 1, internalUser: false))
        #expect(Megaphones.isShowable(snoozed, now: now + Self.day, internalUser: false))
        snoozed.snoozeCount = 2
        #expect(!Megaphones.isShowable(snoozed, now: now + 6 * Self.day, internalUser: false))
        snoozed.snoozeCount = 5
        #expect(Megaphones.lastSnoozeDuration(snoozed) == 7 * Self.day)
        #expect(Megaphones.lastSnoozeDuration(Self.megaphone("a")) == 3 * Self.day)
    }

    /// A stubbed updates2.signal.org: ETags and bodies by path.
    final class Stub: ReleaseNotesTransport, @unchecked Sendable {
        var files: [String: (etag: String, data: Data)] = [:]
        var gets: [String] = []
        func put(_ path: String, _ json: Any, etag: String = "e1") {
            files[path] = (etag, try! JSONSerialization.data(withJSONObject: json))
        }
        func etag(_ url: URL) async throws -> String? { files[url.path]?.etag }
        func get(_ url: URL, maxBytes: Int) async throws -> Data {
            gets.append(url.path)
            guard let f = files[url.path] else { throw ReleaseNotesError.badStatus(404) }
            return f.data
        }
    }

    /// Notes newer than the watermark and up to our version arrive in the Signal chat, title in
    /// bold, with styles moved after it; an unchanged manifest is not read again; megaphones are
    /// saved with their text (images: stored), dropped ones deleted.
    @Test func releaseNotesAndMegaphones() async throws {
        try await LinkedClient.with { c in
            let stub = Stub()
            let manifest: [String: Any] = [
                "announcements": [
                    ["uuid": "n-old", "desktopMinVersion": "8.30.0"],
                    ["uuid": "n-new", "desktopMinVersion": "8.36.0"],
                    ["uuid": "n-future", "desktopMinVersion": "9.0.0"],
                    ["uuid": "n-elsewhere", "desktopMinVersion": "8.36.0", "countries": "*:0"],
                ],
                "megaphones": [["uuid": "m-1", "priority": 100, "desktopMinVersion": "8.0.0", "dontShowBeforeEpochSeconds": 0,
                                "dontShowAfterEpochSeconds": 9_999_999_999, "showForNumberOfDays": 30, "primaryCtaId": "finish"]],
            ]
            stub.put("/dynamic/release-notes/release-notes-v2.json", manifest)
            for id in ["n-old", "n-new", "n-future", "n-elsewhere"] {
                stub.put("/static/release-notes/\(id)/en.json", ["uuid": id, "title": "Hello", "body": "New \(id)",
                                                                 "bodyRanges": [["style": "ITALIC", "start": 0, "length": 3]]])
            }
            stub.put("/static/release-notes/m-1/en.json", ["uuid": "m-1", "title": "Banner", "body": "Read me", "image": "/static/release-notes/m-1.png"])
            stub.files["/static/release-notes/m-1.png"] = ("i", Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
            let service = ReleaseNotesService(account: c.account, database: c.database, store: c.attachmentStore, media: nil, transport: stub,
                                              currentVersion: "8.36.0")
            try await c.database.pool.write { try Items.set($0, "releaseNotesVersionWatermark", "8.35.0") }
            await service.runIfDue(locales: ["nl_nl", "nl", "en"], now: 1_000)

            let chat = try await c.database.pool.read { try String.fetchOne($0, sql: "SELECT id FROM conversations WHERE serviceId = ?",
                                                                            arguments: [StorageLocal.signalAci]) }
            let notes = try await c.database.pool.read { try ConversationQueries.messages($0, conversationId: try #require(chat), limit: 20) }
            #expect(notes.map(\.body) == ["Hello\n\nNew n-new"])
            #expect(notes.first?.bodyRanges == [MessageBodyRange(start: 0, length: 5, kind: .style(1)), MessageBodyRange(start: 7, length: 3, kind: .style(2))])
            #expect(notes.first?.author == StorageLocal.signalAci && notes.first?.direction == .incoming)
            #expect(try await c.database.pool.read { try Items.get($0, "releaseNotesVersionWatermark", as: String.self) } == "8.36.0")

            let saved = try await c.database.pool.read { try Megaphones.all($0) }
            #expect(saved.map(\.id) == ["m-1"] && saved.first?.title == "Banner" && saved.first?.image != nil && saved.first?.localeFetched == "en")

            // Due again a day later; the same manifest hash is not read again.
            let reads = stub.gets.count
            await service.runIfDue(locales: ["en"], now: 1_000 + Self.day)
            #expect(stub.gets.count == reads)

            // The manifest changes: the dropped megaphone goes.
            stub.put("/dynamic/release-notes/release-notes-v2.json", ["announcements": [], "megaphones": []], etag: "e2")
            await service.runIfDue(locales: ["en"], now: 1_000 + 2 * Self.day)
            #expect(try await c.database.pool.read { try Megaphones.all($0) }.isEmpty)
        }
    }

    /// The Desktop version Serein claims (feature flags, announcements) is the one it has been
    /// reviewed up to (Tools/upstream-desktop.txt).
    @Test func desktopVersionMatchesTheReviewedRelease() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pin = try String(contentsOf: root.appendingPathComponent("Tools/upstream-desktop.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = pin.dropFirst().split(separator: "-").first.map(String.init)
        #expect(version == SignalClient.desktopVersion, "Tools/upstream-desktop.txt is \(pin)")
    }
}
