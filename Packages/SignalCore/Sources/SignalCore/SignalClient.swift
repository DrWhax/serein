// The client as the app runs it (upstream background.preload.ts start-up): the encrypted
// database (key in the Keychain), the chat sockets for an environment, linking as a new
// device or the stored account, then every service wired together and the receive loop.
// The media decoder is injected (the app's XPC client; tests pass the in-process one).

import Foundation
import Synchronization
import GRDB
import LibSignalClient
import MediaXPCInterface

public actor SignalClient {
    /// Where the client talks to.
    public struct Config: Sendable {
        public var net: Net
        public var endpoints: ServiceEndpoints
        public var trustRoots: [PublicKey]
        public var serverPublicParams: Data
        public var genericServerPublicParams: Data
        public init(net: Net, endpoints: ServiceEndpoints, trustRoots: [PublicKey], serverPublicParams: Data, genericServerPublicParams: Data) {
            self.net = net
            self.endpoints = endpoints
            self.trustRoots = trustRoots
            self.serverPublicParams = serverPublicParams
            self.genericServerPublicParams = genericServerPublicParams
        }

        public static func signal(_ env: SignalEnvironment, userAgent: String) throws -> Config {
            Config(net: env.net(userAgent: userAgent), endpoints: env.endpoints, trustRoots: try env.serverTrustRoots(),
                   serverPublicParams: env.serverPublicParams, genericServerPublicParams: env.genericServerPublicParams)
        }
    }

    public nonisolated let config: Config
    public nonisolated let database: SignalDatabase
    public let directory: URL
    let net: Net
    public nonisolated let socket: SocketManager
    let media: any MediaProcessing
    let endpoints: ServiceEndpoints
    let trustRoots: [PublicKey]
    public private(set) var session: Session?

    /// Everything that needs an account.
    public struct Session: Sendable {
        public let account: Account
        public let jobs: JobQueue
        public let messenger: Messenger
        public let receiver: MessageReceiver
        public let profiles: ProfileService
        public let storage: StorageService
        public let groups: GroupsService
        public let stickers: StickerService
        public let downloads: AttachmentDownloadManager
        public let attachmentStore: AttachmentStore
        public let http: HTTPClient
        /// Find by phone number (CDSI) and by username.
        public let discovery: ContactDiscovery
        public let usernames: UsernameService
    }

    public init(config: Config, directory: URL, keyStore: any DatabaseKeyStore = KeychainDatabaseKeyStore(), media: any MediaProcessing) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.config = config
        self.directory = directory
        database = try SignalDatabase(url: directory.appendingPathComponent("db.sqlite"), key: try keyStore.loadOrCreateKey())
        net = config.net
        socket = SocketManager(net: net)
        self.media = media
        endpoints = config.endpoints
        trustRoots = config.trustRoots
    }

    /// The stored account, if this device is linked.
    public func storedAccount() async throws -> Account? { try await database.pool.read { try Account.load($0) } }

    /// Links as a new device: `onURL` gets the `sgnl://linkdevice` URL to show as a QR code.
    public func link(deviceName: String, onURL: @escaping @Sendable (String) -> Void) async throws -> Account {
        let linker = DeviceLinker(net: net, socket: socket, database: database)
        let account = try await linker.link(LinkOptions(deviceName: deviceName), onURL: onURL)
        try await start(account, uploadOneTimeKeys: linker)
        return account
    }

    /// Starts the stored account's session.
    @discardableResult
    public func resume() async throws -> Session? {
        guard let account = try await storedAccount() else { return nil }
        await socket.setCredentials(account.credentials)
        try await start(account, uploadOneTimeKeys: nil)
        return session
    }

    func start(_ account: Account, uploadOneTimeKeys linker: DeviceLinker?) async throws {
        let jobs = JobQueue(database: database)
        let http = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER)
        let store = try AttachmentStore(root: directory.appendingPathComponent("attachments"))
        let services = AttachmentServices(store: store, uploader: AttachmentUploader(http: http, forms: socket), media: media)
        let messenger = Messenger(account: account, database: database, socket: socket, trustRoots: trustRoots, jobs: jobs, attachments: services)
        let downloads = AttachmentDownloadManager(db: database.pool, http: http, endpoints: endpoints, store: store, media: media)
        let credentials = GroupCredentials(account: account, socket: socket, db: database.pool, serverPublicParams: config.serverPublicParams,
                                           genericServerPublicParams: config.genericServerPublicParams)
        let groups = GroupsService(account: account, database: database, api: GroupsAPI(http: http, endpoints: endpoints, credentials: credentials),
                                   store: store)
        let storage = StorageService(account: account, database: database, socket: socket, http: http, endpoints: endpoints)
        let contactSync = ContactSync(database: database, http: http, endpoints: endpoints)
        let stickers = StickerService(account: account, database: database, http: http, endpoints: endpoints, store: store, media: media)
        let profiles = ProfileService(account: account, database: database, socket: socket, http: http, cdn0: endpoints.cdnURLs[0], store: store)
        await messenger.register()
        await stickers.register(on: jobs)
        await storage.register(on: jobs)
        await contactSync.register(on: jobs)
        await jobs.start()
        let receiver = MessageReceiver(account: account, database: database, trustRoots: trustRoots, jobs: jobs)
        let params = config.serverPublicParams
        await groups.configure(credentials: { aci in try await profiles.expiringCredential(aci, serverPublicParams: params) },
                               sender: messenger.groupSender)
        // Storage-sync follow-ups run in the background (upstream queues them), four at a time,
        // so a large account's first sync does not wait for every profile and group fetch.
        storage.setHooks(profileFetch: { ids in
            Task.detached(priority: .utility) {
                let failed = Mutex(0)
                await Self.forEach(ids, concurrency: 4) { id in
                    do { _ = try await profiles.fetch(id) } catch { failed.withLock { $0 += 1 } }
                }
                Self.diagnose("profiles fetched: \(ids.count), failed \(failed.withLock { $0 })")
            }
        }, groupUpdate: { keys in
            Task.detached(priority: .utility) {
                let failed = Mutex<[String]>([])
                await Self.forEach(keys, concurrency: 4) { mk in
                    do { _ = try await groups.update(try GroupKeys(masterKey: mk)) } catch { failed.withLock { $0.append(String(describing: error).prefix(80).description) } }
                }
                let f = failed.withLock { $0 }
                Self.diagnose("groups fetched: \(keys.count), failed \(f.count)\(f.isEmpty ? "" : ", first: \(f[0])")")
            }
        })
        session = Session(account: account, jobs: jobs, messenger: messenger, receiver: receiver, profiles: profiles, storage: storage,
                          groups: groups, stickers: stickers, downloads: downloads, attachmentStore: store, http: http,
                          discovery: ContactDiscovery(net: net, database: database, socket: socket),
                          usernames: UsernameService(account: account, database: database, socket: socket))
        try await socket.connect(listener: receiver)
        if let linker { try await linker.uploadOneTimePreKeys(for: account) }
        try await downloads.start()
    }

    /// Fills in what an interrupted or partial first sync left out: every group with no stored
    /// state (its name, members, avatar) and every contact whose profile key we have but whose
    /// profile name we do not. Background work, four requests at a time.
    public func refreshIncomplete() async {
        guard let session else { return }
        let todo = try? await database.pool.read { db -> (groups: [Data], profiles: [String]) in
            var groups: [Data] = []
            for id in try String.fetchAll(db, sql: """
                SELECT id FROM conversations WHERE type = 'group' AND coalesce(json_extract(json, '$.left'), 0) = 0
                """) {
                if let stored = try GroupStore.load(db, conversationId: id), stored.state == nil { groups.append(stored.keys.masterKey) }
            }
            var profiles: [String] = []
            for row in try Row.fetchAll(db, sql: "SELECT serviceId, json, profileName FROM conversations WHERE type = 'private' AND serviceId IS NOT NULL") {
                let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
                let hasName = !((json["profileName"] as? String) ?? (row["profileName"] as String?) ?? "").isEmpty
                // Never fetched, no name, or an avatar not downloaded yet (older builds kept only its CDN path).
                let avatar = json["profileAvatar"] as? [String: Any]
                let avatarPending = avatar != nil && avatar?["localKey"] == nil
                let stale = !hasName || avatarPending || json["profileLastFetchedAt"] == nil
                if json["profileKey"] != nil, stale, let id: String = row["serviceId"] { profiles.append(id) }
            }
            return (groups, profiles)
        }
        guard let todo else { return }
        Self.diagnose("refresh: \(todo.groups.count) groups without state, \(todo.profiles.count) profiles to fetch")
        let groupFailures = Mutex<[String]>([])
        let done = Mutex(0)
        let total = todo.groups.count
        await Self.forEach(todo.groups, concurrency: 4) { mk in
            let start = ContinuousClock.now
            var outcome = "ok"
            do {
                try await Self.withTimeout(.seconds(90)) { _ = try await session.groups.update(try GroupKeys(masterKey: mk)) }
            } catch {
                outcome = String(describing: error).prefix(80).description
                groupFailures.withLock { $0.append(outcome) }
            }
            let n = done.withLock { $0 += 1; return $0 }
            Self.diagnose("refresh: group \(n)/\(total) \(outcome) in \(ContinuousClock.now - start)")
        }
        let gf = groupFailures.withLock { $0 }
        Self.diagnose("refresh: groups done, failed \(gf.count)\(gf.isEmpty ? "" : ", first: \(gf[0])")")
        let profileFailures = Mutex(0)
        await Self.forEach(todo.profiles, concurrency: 4) { id in
            do { _ = try await session.profiles.fetch(id) } catch { profileFailures.withLock { $0 += 1 } }
        }
        Self.diagnose("refresh: profiles done, failed \(profileFailures.withLock { $0 })")
    }

    /// Diagnostics for the app's log (counts and error kinds only, never content).
    public static let diagnostics = Mutex<(@Sendable (String) -> Void)?>(nil)
    static func diagnose(_ line: String) { diagnostics.withLock { $0 }?(line) }

    struct TimedOut: Error, CustomStringConvertible { var description: String { "timed out" } }

    /// `body`, or `TimedOut` after `limit` (the body is cancelled).
    static func withTimeout(_ limit: Duration, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: limit); throw TimedOut() }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Runs `body` over `items`, at most `concurrency` at once.
    static func forEach<T: Sendable>(_ items: [T], concurrency: Int, _ body: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(concurrency, items.count) {
                let item = items[next]
                next += 1
                group.addTask { await body(item) }
            }
            while await group.next() != nil, next < items.count {
                let item = items[next]
                next += 1
                group.addTask { await body(item) }
            }
        }
    }

    /// The receive pipeline's events, with groups kept current and downloads nudged.
    public func events() -> AsyncStream<ReceiveEvent> {
        guard let session else { return AsyncStream { $0.finish() } }
        let (stream, sink) = AsyncStream<ReceiveEvent>.makeStream()
        Task {
            for await e in session.receiver.events {
                if case .message = e { await session.downloads.tick() }
                if case .groupContext(let masterKey, let revision, let change, _, let timestamp) = e, let keys = try? GroupKeys(masterKey: masterKey) {
                    _ = try? await session.groups.update(keys, newRevision: revision, groupChange: change, timestamp: timestamp)
                }
                sink.yield(e)
            }
            sink.finish()
        }
        return stream
    }
}
