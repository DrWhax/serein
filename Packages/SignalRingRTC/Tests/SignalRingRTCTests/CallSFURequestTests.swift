import CryptoKit
import Foundation
import RingRTCNative
import Testing
@testable import SwiftCallingServiceAdapter
@testable import SignalRingRTC
@testable import SwiftCalling

@Suite(.serialized) struct CallSFURequestTests {
    private func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    // RFC 8452, Appendix C.2. Includes a non-block-aligned record.
    @Test func cipherVectors() throws {
        let key = SymmetricKey(data: [1] + Array(repeating: UInt8(0), count: 31))
        let cipher = try CallLinkRecordCipher(key: key, nonce: [3] + Array(repeating: 0, count: 11))
        #expect(hex(cipher.seal([])) == "07f5f4169bbf55a8400cd47ea6fd400f")
        let plain = [1] + Array(repeating: UInt8(0), count: 7)
        var record = cipher.seal(plain)
        #expect(hex(record) == "c2ef328e5c71c83b843122130f7364b761e0b97427e3df28")
        #expect(try cipher.open(record) == plain)
        record[0] ^= 1
        #expect(throws: (any Error).self) { try cipher.open(record) }
    }

    private func fixtureKey() throws -> CallLinkRootKey {
        try CallLinkRootKey.fromBytes(Data(0..<16))
    }

    @Test func authenticatedRosterUsesTheSameMembersAndEncryptedTitleAsHTTP() throws {
        let aci = Data(repeating: 1, count: 16), cipher = Data([7, 9])
        let opaque = hex(Array(SHA256.hash(data: cipher)))
        let members: [JSONValue] = [.object(["userId": .bytes(aci), "userIdCipherText": .bytes(cipher)])]
        var roster = GroupSFUUpdate.Peek()
        roster.creator = opaque
        roster.eraID = "abc"
        roster.devices = [.init(demuxID: 16, opaqueUserID: opaque, requiresSVC: true)]
        roster.pendingDevices = [.init(demuxID: 32, opaqueUserID: opaque, requiresSVC: false)]
        let group = try CallSFURequests.inCallPeek(roster, members: members, rootKey: nil)
        #expect(group["creator"].data == aci && group["devices"].array.first?["userId"].data == aci)
        #expect(group["pendingUsers"].array.map(\.data) == [aci] && group["deviceCountIncludingPendingDevices"].int == 2)

        let root = try fixtureKey()
        let title = try CallLinkNameCipher(rootKey: root.bytes).seal("Practice room")
        roster.linkState = .init(encryptedName: title.base64EncodedString(), restrictions: 1, revoked: false, expiration: 1234)
        let link = try CallSFURequests.inCallPeek(roster, members: [], rootKey: root.bytes)
        #expect(link["callLinkState"]["name"].string == "Practice room" && link["opaqueCreator"].string == opaque)
        #expect(link["pendingDevices"].array.first?["opaqueUserId"].string == opaque)
        roster.devices[0].demuxID = nil
        #expect(throws: (any Error).self) { try CallSFURequests.inCallPeek(roster, members: members, rootKey: nil) }
    }

    @MainActor @Test(arguments: [false, true])
    func encryptedTitleInteroperatesWithNative(swiftWriter: Bool) async throws {
        let writer = try RingRTC(endpoint: swiftWriter ? SwiftVoiceEndpoint.factory : NativeEndpoint.factory)
        let reader = try RingRTC(endpoint: swiftWriter ? NativeEndpoint.factory : SwiftVoiceEndpoint.factory)
        let key = try CallLinkRootKey.generate().issued(epoch: 0x12345678)
        let title = "Afternoon music ☀️"
        let base = "https://sfu.example/path///"
        var reply = Data()
        writer.handleSendHttpRequest = { id, url, method, headers, data in
            #expect(url == "https://sfu.example/path/v1/call-link" && method == .put)
            #expect(headers["Authorization"] == "Bearer auth.CQ==" && headers["X-Epoch"] == "305419896")
            guard let data, let body = try? JSONDecoder().decode(JSONValue.self, from: data), let encrypted = body["name"].data else {
                Issue.record("Missing encrypted name")
                writer.httpRequestFailed(requestId: id, debugInfo: nil)
                return
            }
            #expect(encrypted.count == 80 && encrypted.range(of: Data(title.utf8)) == nil)
            #expect(body["adminPasskey"].data == Data([42]))
            reply = Data("{\"name\":\"\(encrypted.base64EncodedString())\",\"revoked\":false,\"restrictions\":\"adminApproval\",\"expiration\":1357}".utf8)
            writer.receivedHttpResponse(requestId: id, status: 200, body: reply)
        }
        guard case .success(let written) = await writer.updateCallLinkName(sfuUrl: base, authCredentialPresentation: Data([9]), linkRootKey: key,
                                                                          adminPasskey: Data([42]), newName: title) else {
            Issue.record("Failed to update call link")
            return
        }
        #expect(written.name == title)
        reader.handleSendHttpRequest = { id, _, method, headers, body in
            #expect(body == nil && method == .get && headers["X-Room-Id"]?.count == 64)
            reader.receivedHttpResponse(requestId: id, status: 200, body: reply)
        }
        guard case .success(let state) = await reader.readCallLink(sfuUrl: base, authCredentialPresentation: Data([9]), linkRootKey: key) else {
            Issue.record("Failed to read encrypted call link")
            return
        }
        #expect(state.name == title && state.rootKey == key && state.restrictions == .adminApproval)
        #expect(state.expiration == Date(timeIntervalSince1970: 1357))
        reader.handleSendHttpRequest = nil
        writer.handleSendHttpRequest = nil
    }

    @MainActor @Test func participantsAndLinkLifecycle() async throws {
        let rtc = try RingRTC(endpoint: SwiftVoiceEndpoint.factory)
        defer { rtc.handleSendHttpRequest = nil }
        let key = try CallLinkRootKey.generate()
        rtc.handleSendHttpRequest = { id, _, method, headers, _ in
            #expect(method == .put && headers["X-Epoch"] == nil && headers["Authorization"] == "Bearer create.AQ==")
            rtc.receivedHttpResponse(requestId: id, status: 201, body: Data(#"{"name":"","restrictions":"none","revoked":false,"expiration":10,"epoch":0}"#.utf8))
        }
        let created = await rtc.createCallLink(sfuUrl: "https://sfu.example", createCredentialPresentation: Data([1]), linkRootKey: key,
                                               adminPasskey: Data([9]), callLinkPublicParams: Data([5]), restrictions: .none)
        guard case .success(let link) = created else { Issue.record("create failed"); return }
        #expect(link.rootKey.epoch == 0 && !link.rootKey.awaitingEpoch)
        rtc.handleSendHttpRequest = { id, _, method, headers, _ in
            #expect(method == .delete && headers["X-Epoch"] == "0")
            rtc.receivedHttpResponse(requestId: id, status: 200, body: Data("{}".utf8))
        }
        guard case .success = await rtc.deleteCallLink(sfuUrl: "https://sfu.example", authCredentialPresentation: Data(), linkRootKey: link.rootKey,
                                                      adminPasskey: Data([9])) else { Issue.record("delete failed"); return }
        let ciphertext = Data([1, 2, 3]), aci = Data(repeating: 9, count: 16)
        let opaque = hex(Array(SHA256.hash(data: ciphertext)))
        rtc.handleSendHttpRequest = { id, url, method, headers, _ in
            #expect(url.hasSuffix("/v2/conference/participants") && method == .get)
            #expect(headers["Authorization"] == "Basic " + Data("member:member:proof".utf8).base64EncodedString())
            let device = "{\"demuxId\":16,\"opaqueUserId\":\"\(opaque)\"}"
            rtc.receivedHttpResponse(requestId: id, status: 200, body: Data("{\"participants\":[\(device)],\"creator\":\"\(opaque)\",\"pendingClients\":[\(device),\(device)]}".utf8))
        }
        let info = await rtc.peekGroupCall(sfuUrl: "https://sfu.example", membershipProof: Data("member:proof".utf8),
                                           groupMembers: [.init(userId: aci, userIdCipherText: ciphertext)])
        #expect(info.devices.first?.userId == aci && info.creator == aci && info.pendingUsers == [aci] && info.deviceCount == 3)
        rtc.handleSendHttpRequest = { id, _, _, _, _ in
            rtc.receivedHttpResponse(requestId: id, status: 200, body: Data(#"{"participants":[{"demuxId":16,"opaqueUserId":"010203"}],"creator":"010203","pendingClients":[{"demuxId":32,"opaqueUserId":"010203"}]}"#.utf8))
        }
        var decryptions = 0
        let peek = await rtc.peekCallLinkCall(sfuUrl: "https://sfu.example", authCredentialPresentation: Data(), rootKey: link.rootKey) {
            decryptions += 1
            return $0 == ciphertext ? aci : nil
        }
        guard case .success(let resolved) = peek else { Issue.record("peek failed"); return }
        #expect(resolved.creator == aci && resolved.pendingUsers == [aci] && resolved.devices.first?.userId == aci && decryptions == 1)
    }

    @Test func interleavedResponsesAndFailures() throws {
        let endpoint = try SwiftVoiceEndpoint.factory("")
        defer { endpoint.close() }
        let fields: [String: JSONValue] = ["requestId": .int(1), "rootKey": .bytes(try fixtureKey().bytes), "sfuUrl": .string("https://sfu.example"),
                                          "authPresentation": .bytes(Data()), "adminPasskey": .bytes(Data())]
        for name in ["peekCallLinkCall", "readCallLink", "deleteCallLink"] { _ = try endpoint.command(name, fields) }
        guard case .events(let requests) = endpoint.waitEvents(timeoutMs: 0) else { Issue.record("endpoint lost"); return }
        try #require(requests.count == 3 && Set(requests.compactMap { $0["requestId"].int }).count == 3)
        _ = try endpoint.command("receivedHttpResponse", ["requestId": requests[2]["requestId"], "statusCode": .int(200), "body": .bytes(Data())])
        _ = try endpoint.command("receivedHttpResponse", ["requestId": requests[0]["requestId"], "statusCode": .int(404), "body": .bytes(Data(#"{"reason":"expired"}"#.utf8))])
        for _ in 0..<2 { _ = try endpoint.command("httpRequestFailed", ["requestId": requests[1]["requestId"]]) }
        guard case .events(let results) = endpoint.waitEvents(timeoutMs: 0) else { Issue.record("endpoint lost"); return }
        #expect(results.compactMap { $0["status"].int } == [702, 703, 602])
        #expect(results.compactMap { $0["type"].string } == ["handleEmptyResponse", "handlePeekResponse", "handleCallLinkResponse"])
        #expect(results.allSatisfy { $0["requestId"].int == 1 })
    }
}
