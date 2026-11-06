import Foundation
import Testing
@testable import SignalRingRTC

@Suite(.serialized) struct NativeTests {
    @Test func endpointLifecycle() throws {
        let ep = try #require(NativeEndpoint(fieldTrials: "RingRTC-PruneTurnPorts/Enabled/"))
        // Audio devices come from cubeb.
        let inputs = try ep.command("getAudioInputs")
        #expect(inputs["devices"].array.count >= 0 && inputs["defaults"]["isWindows"] == .bool(false), "\(inputs)")
        // Static commands work without an endpoint.
        let key = try NativeEndpoint.command(0, "callLinkRootKeyGenerate")
        let bytes = try #require(key.data)
        #expect(bytes.count == 21, "\(bytes.count)")   // ringrtc v1 root key
        let formatted = try NativeEndpoint.command(0, "callLinkRootKeyToFormattedString", ["bytes": .bytes(bytes)])
        let parsed = try NativeEndpoint.command(0, "callLinkRootKeyParse", ["string": formatted])
        #expect(parsed.data == bytes)
        // Events can be drained (log messages are process-wide: whichever endpoint drains
        // first gets them, so only the shape is checked here).
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let events = ep.waitEvents(timeoutMs: 100, buffer: &buffer)
        #expect(events.allSatisfy { $0["type"].string != nil })
        // Errors come back as errors.
        #expect(throws: RingRTCError.self) { try ep.command("noSuchCommand") }
        #expect(throws: RingRTCError.self) { try ep.command("accept", ["callId": .string("not a number")]) }
    }
}
