// A SignalCore client linked to the mock server's "phone" account: receive pipeline
// on the authenticated socket, persistent job queue with the messenger (sends,
// receipts, resends), contact sync and storage-service handlers, profiles.

import Foundation
import LibSignalClient
import Synchronization
import Testing
import GRDB
import SignalMediaDecoder
@testable import SignalCore

/// Step trace on stderr when SIGNALSAFE_TRACE is set (also enables mock-server debug logs).
func trace(_ s: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SIGNALSAFE_TRACE"] != nil else { return }
    try? FileHandle.standardError.write(contentsOf: Data("[trace] \(s())\n".utf8))
}

/// Collects ReceiveEvents so tests can wait for one matching a predicate.
actor EventLog {
    private(set) var events: [ReceiveEvent] = []
    func append(_ e: ReceiveEvent) { events.append(e) }

    func waitFor(timeout: Duration = .seconds(20), _ what: String = "event",
                 _ match: @Sendable (ReceiveEvent) -> Bool) async throws -> ReceiveEvent {
        let deadline = ContinuousClock.now + timeout
        var seen = 0
        while ContinuousClock.now < deadline {
            while seen < events.count {
                let e = events[seen]
                seen += 1
                if match(e) { return e }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessError(description: "timed out waiting for \(what); got \(events)")
    }
}

struct LinkedClient: Sendable {
    let server: MockServerHarness
    let database: SignalDatabase
    let databaseURL: URL
    let socket: SocketManager
    let linker: DeviceLinker
    let account: Account
    let receiver: MessageReceiver
    let log: EventLog
    let net: Net
    let jobs: JobQueue
    let messenger: Messenger
    let profiles: ProfileService
    let storage: StorageService
    let contactSync: ContactSync
    let endpoints: ServiceEndpoints
    let attachmentStore: AttachmentStore
    let downloads: AttachmentDownloadManager
    let groups: GroupsService
    let stickers: StickerService
    let groupCredentials: GroupCredentials

    var aliceAci: String { server.ready.alice.aci.lowercased() }
    var phoneAci: String { server.ready.phone.aci.lowercased() }

    /// Starts a mock server, links a client, runs `body`, and always tears both down.
    static func with(_ body: (LinkedClient) async throws -> Void) async throws {
        let server = try await MockServerHarness.start()
        let client: LinkedClient
        do { client = try await link(server) } catch {
            await server.stop()
            throw error
        }
        do { try await body(client) } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    static func temporaryDatabase() throws -> (SignalDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-\(UUID()).sqlite")
        return (try SignalDatabase(url: url, key: SignalCrypto.randomBytes(32)), url)
    }

    static func link(_ server: MockServerHarness, deviceName: String = "SignalSafe tests", oneTimeKeys: Int = 20) async throws -> LinkedClient {
        trace("link: start")
        let (database, url) = try temporaryDatabase()
        let net = Net.localTestServer(userAgent: "SignalSafe-Tests", chatPort: UInt16(server.ready.port),
                                      rootCertificateDer: server.ready.certificateAuthorityDER)
        let socket = SocketManager(net: net)
        let linker = DeviceLinker(net: net, socket: socket, database: database)

        // The QR URL goes to the mock "phone", which completes provisioning while link() waits.
        let (urls, urlSink) = AsyncStream<String>.makeStream()
        let primary = Task {
            for await url in urls {
                trace("link: provisioning URL \(url)")
                let r = try await server.call("provision", ["url": url])
                trace("link: primary completed provisioning")
                return r
            }
            throw HarnessError(description: "no provisioning URL")
        }
        let account = try await linker.link(LinkOptions(deviceName: deviceName, oneTimePreKeyCount: oneTimeKeys)) { url in
            urlSink.yield(url)
            urlSink.finish()
        }
        trace("link: linked as device \(account.deviceId)")

        let jobs = JobQueue(database: database, policy: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(100), maxDelay: .seconds(2)))
        let endpoints = ServiceEndpoints.mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER)
        let http = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER)
        let attachmentStore = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-attachments-\(UUID())"))
        let services = AttachmentServices(store: attachmentStore, uploader: AttachmentUploader(http: http, forms: socket), media: MediaDecoder())
        let messenger = Messenger(account: account, database: database, socket: socket, trustRoots: server.ready.trustRoots, jobs: jobs,
                                  attachments: services)
        let downloads = AttachmentDownloadManager(db: database.pool, http: http, endpoints: endpoints, store: attachmentStore, media: MediaDecoder())
        let groupCredentials = GroupCredentials(account: account, socket: socket, db: database.pool,
                                                serverPublicParams: Data(base64Encoded: server.ready.serverPublicParams)!,
                                                genericServerPublicParams: Data(base64Encoded: server.ready.genericServerPublicParams)!)
        let groups = GroupsService(account: account, database: database,
                                   api: GroupsAPI(http: http, endpoints: endpoints, credentials: groupCredentials), store: attachmentStore)
        let storage = StorageService(account: account, database: database, socket: socket, http: http, endpoints: endpoints)
        let contactSync = ContactSync(database: database, http: http, endpoints: endpoints)
        let stickers = StickerService(account: account, database: database, http: http, endpoints: endpoints, store: attachmentStore, media: MediaDecoder())
        await messenger.register()
        await stickers.register(on: jobs)
        await storage.register(on: jobs)
        await contactSync.register(on: jobs)
        await jobs.start()

        let receiver = MessageReceiver(account: account, database: database, trustRoots: server.ready.trustRoots, jobs: jobs)
        let log = EventLog()
        Task {
            for await e in receiver.events {
                await log.append(e)
                if case .message = e { await downloads.tick() }
                if case .groupContext(let masterKey, let revision, let change, _, let timestamp) = e, let keys = try? GroupKeys(masterKey: masterKey) {
                    do { try await groups.update(keys, newRevision: revision, groupChange: change, timestamp: timestamp) } catch {
                        trace("group update failed: \(error)")
                    }
                    await log.append(.other(kind: "groupUpdated", sender: keys.groupIdBase64))
                }
            }
        }
        try await socket.connect(listener: receiver)
        trace("link: authenticated socket up")
        try await linker.uploadOneTimePreKeys(for: account)
        trace("link: one-time keys uploaded")
        // The mock primary reports completion once the new device has uploaded keys for ACI and PNI.
        _ = try await primary.value
        try await downloads.start()
        let profileService = ProfileService(account: account, database: database, socket: socket)
        let params = Data(base64Encoded: server.ready.serverPublicParams)!
        await groups.configure(credentials: { aci in try await profileService.expiringCredential(aci, serverPublicParams: params) },
                               sender: messenger.groupSender)
        storage.setHooks(profileFetch: { ids in for id in ids { _ = try? await profileService.fetch(id) } },
                         groupUpdate: { keys in
                             for mk in keys { if let k = try? GroupKeys(masterKey: mk) { _ = try? await groups.update(k) } }
                         })
        return LinkedClient(server: server, database: database, databaseURL: url, socket: socket, linker: linker, account: account,
                            receiver: receiver, log: log, net: net, jobs: jobs, messenger: messenger,
                            profiles: ProfileService(account: account, database: database, socket: socket),
                            storage: storage, contactSync: contactSync, endpoints: endpoints, attachmentStore: attachmentStore, downloads: downloads,
                            groups: groups, stickers: stickers, groupCredentials: groupCredentials)
    }

    /// Polls the database until `check` holds.
    func eventually(_ what: String, timeout: Duration = .seconds(15), _ check: @Sendable (Database) throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await database.pool.read({ db in try check(db) }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessError(description: "timed out waiting for \(what)")
    }

    func conversationJSON(serviceId: String) async throws -> [String: Any] {
        let json = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId])
        }
        return try MessageStore.jsonObject(try #require(json))
    }

    /// We share our profile with alice (an accepted chat: her media downloads by itself).
    func acceptAlice() async throws {
        let aci = aliceAci
        try await database.pool.write { db in
            let id = try MessageStore.privateConversation(db, serviceId: aci)
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["profileSharing"] = true }
        }
    }

    func messageJSON(sentAt: UInt64) async throws -> [String: Any] {
        let json = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM messages WHERE sent_at = ?", arguments: [Int64(sentAt)])
        }
        return try MessageStore.jsonObject(try #require(json))
    }

    func close() async {
        await downloads.stop()
        await jobs.stop()
        await socket.disconnect()
        await server.stop()
        // Test databases and attachment folders are temporary: remove them.
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databaseURL.path + suffix) }
        try? FileManager.default.removeItem(at: attachmentStore.root)
    }
}

/// Distinct, increasing client timestamps (ms) for test messages.
enum TestClock {
    static let last = Mutex<UInt64>(0)
    static func next() -> UInt64 {
        last.withLock { last in
            last = max(last + 1, UInt64(Date().timeIntervalSince1970 * 1000))
            return last
        }
    }
}
