// The app's client against the mock server: link, then a fresh client on the same folder
// resumes the stored account and receives.

import Foundation
import GRDB
import LibSignalClient
import SignalMediaDecoder
import Testing
@testable import SignalCore

struct FixedKeyStore: DatabaseKeyStore {
    let key: Data
    func loadOrCreateKey() throws -> Data { key }
    func deleteKey() throws {}
}

@Suite(.serialized) struct SignalClientTests {
    @Test func linksThenResumesAfterRestart() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = FixedKeyStore(key: SignalCrypto.randomBytes(32))
        func config() -> SignalClient.Config {
            SignalClient.Config(net: Net.localTestServer(userAgent: "SignalSafe-Tests", chatPort: UInt16(server.ready.port),
                                                         rootCertificateDer: server.ready.certificateAuthorityDER),
                                endpoints: .mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER),
                                trustRoots: server.ready.trustRoots, serverPublicParams: Data(base64Encoded: server.ready.serverPublicParams)!,
                                genericServerPublicParams: Data(base64Encoded: server.ready.genericServerPublicParams)!)
        }
        let first = try SignalClient(config: config(), directory: dir, keyStore: keys, media: MediaDecoder())
        #expect(try await first.storedAccount() == nil)
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let account = try await first.link(deviceName: "SignalSafe test") { url in sink.yield(url); sink.finish() }
        _ = try await phone.value
        #expect(account.deviceId > 1)

        // A new process: same folder and key, no linking.
        await first.shutdown()
        let second = try SignalClient(config: config(), directory: dir, keyStore: keys, media: MediaDecoder())
        let session = try #require(try await second.resume())
        #expect(session.account.aci == account.aci)
        // The resumed session keeps house: expiring messages and pins on a timer, pre-keys on theirs.
        #expect(await session.maintenance.isRunning)
        let events = await second.events()
        let t = TestClock.next()
        try await server.call("sendText", ["from": "alice", "text": "after restart", "timestamp": t])
        for await e in events {
            if case .message(_, _, _, _, t, let body, _, _) = e { #expect(body == "after restart"); break }
        }
        // What the app shows: the inbox row with its preview, then the reply in the timeline.
        var inbox = second.database.inboxUpdates().makeAsyncIterator()
        let rows = try #require(try await inbox.next())
        let chat = try #require(rows.first)
        #expect(chat.kind == .private && chat.unreadCount == 1 && chat.lastMessage?.body == "after restart")
        var timeline = second.database.timelineUpdates(conversationId: chat.id).makeAsyncIterator()
        #expect(try await timeline.next()?.map(\.body) == ["after restart"])
        _ = try await session.messenger.sendText("reply", to: try #require(chat.serviceId))
        while let next = try await timeline.next() {
            if next.last?.body == "reply", next.last?.status == .sent { break }
        }
        #expect(try await inbox.next()?.first?.lastMessage?.direction == .outgoing)
        await second.shutdown()
        await server.stop()
    }
}
