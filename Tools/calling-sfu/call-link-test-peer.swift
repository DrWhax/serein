import Foundation
@testable import SignalCore
import SignalRingRTC
@testable import SignalSafe

@main struct CallTestPeerQA {
    struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

    static func report(_ message: String) {
        FileHandle.standardError.write(Data(("PEER-QA " + message + "\n").utf8))
    }

    @MainActor static func wait(_ name: String, seconds: Int, _ test: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while try !test() {
            guard ContinuousClock.now < deadline else { throw Failure("Timed out waiting for " + name) }
            try await Task.sleep(for: .milliseconds(100))
        }
        report(name)
    }

    @MainActor static func verifyMedia(_ session: SignalSession, roomID: String, otherDevice: UInt32? = nil) async throws {
        var firstImage: Data?
        var distinctFrames = 0
        var peak = 0.0
        var hasDevice = false
        var count = 0
        var reportAt = ContinuousClock.now
        var rgba = [UInt8](repeating: 0, count: 960 * 540 * 4)
        try await wait("native peer produced changing video and decoded audio in Serein", seconds: 80) {
            if case .failed(let message) = session.localCallTestPeerState { throw Failure(message) }
            if ContinuousClock.now >= reportAt {
                report("progress state=\(session.localCallTestPeerState) remote=\(hasDevice) videoFrames=\(count) peak=\(peak)")
                reportAt = ContinuousClock.now.advanced(by: .seconds(5))
            }
            let group = session.calling?.groupCall(for: roomID)
            guard let testID = session.localCallTestPeerDemuxId, let devices = group?.remoteDeviceStates,
                  Set(devices.map(\.demuxId)) == Set([testID, otherDevice].compactMap { $0 }),
                  let remote = devices.first(where: { $0.demuxId == testID }) else { return false }
            hasDevice = true
            peak = max(peak, Double(remote.audioLevel))
            if let (width, height) = session.groupVideoSource(roomID, remote.demuxId)
                .receiveVideoFrame(into: &rgba, maxWidth: 960, maxHeight: 540), width > 0, height > 0 {
                // Require non-flat RGB content and a change between decoded frames. Skip alpha.
                let strideBytes = 4 * max(1, width * height / 401)
                let sample = Data(stride(from: 0, to: width * height * 4, by: strideBytes).map { rgba[$0] })
                if let min = sample.min(), let max = sample.max(), Int(max) - Int(min) > 24 {
                    if let first = firstImage, first != sample { distinctFrames += 1 }
                    else if firstImage == nil { firstImage = sample }
                }
                count += 1
            }
            return session.localCallTestPeerState == .running && distinctFrames >= 2 && peak > 0
        }
        report("received \(count) frames, decoded peak \(peak)")
    }

    enum ScreenPattern {
        case initial, inverted, stopped

        func bright(row: Int, column: Int) -> Bool {
            switch self {
            case .initial: row != column
            case .inverted: row == column
            case .stopped: row == 1
            }
        }

        func matchingSamples(width: Int, height: Int, rgba: [UInt8]) -> Int {
            guard width >= 64, height >= 36, width * height * 4 <= rgba.count else { return 0 }
            // Check all channels at nine points in each quadrant, away from its edges.
            var matches = 0
            for row in 0..<2 {
                for column in 0..<2 {
                    let light = bright(row: row, column: column)
                    for y in 3...5 {
                        for x in 3...5 {
                            let pixelY = (row * 8 + y) * height / 16
                            let pixelX = (column * 8 + x) * width / 16
                            let offset = (pixelY * width + pixelX) * 4
                            let rgb = rgba[offset..<(offset + 3)]
                            if rgb.allSatisfy({ light ? $0 >= 175 : $0 <= 80 }) { matches += 1 }
                        }
                    }
                }
            }
            return matches
        }
    }

    @MainActor static func verifyScreenShare(_ session: SignalSession, roomID: String) async throws {
        guard let calling = session.calling, let primary = calling.groupCall(for: roomID)?.localDeviceState.demuxId,
              let native = calling.localCallLinkTestPeer?.call, native.localDeviceState.demuxId == session.localCallTestPeerDemuxId else {
            throw Failure("Missing native receiving endpoint")
        }
        let screen = FixtureShareWindow()
        defer { screen.stop(in: session) }
        try await screen.start(in: session)
        var rgba = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        for (phase, pattern) in [ScreenPattern.initial, .inverted].enumerated() {
            if pattern == .inverted { screen.advance() }
            var decoded = 0
            var reportAt = ContinuousClock.now.advanced(by: .seconds(5))
            try await wait("RingRTC decoded shared window pattern \(phase + 1)", seconds: 35) {
                if case .failed(let reason) = session.localCallTestPeerState { throw Failure(reason) }
                let remote = native.remoteDeviceStates?.first { $0.demuxId == primary }
                if ContinuousClock.now >= reportAt {
                    report("screen progress decoded=\(decoded) presenting=\(remote?.presenting == true) sharing=\(remote?.sharingScreen == true)")
                    reportAt = ContinuousClock.now.advanced(by: .seconds(5))
                }
                guard let (width, height) = native.receiveVideoFrame(demuxId: primary, into: &rgba, maxWidth: 1280, maxHeight: 720) else { return false }
                decoded += 1
                let matches = pattern.matchingSamples(width: width, height: height, rgba: rgba)
                guard matches >= 32, remote?.presenting == true, remote?.sharingScreen == true else { return false }
                report("native screen frame \(width)×\(height), \(matches)/36 samples matched")
                return true
            }
        }
        session.togglePresenting()
        try await wait("RingRTC saw sharing stop and the owner stayed in the call", seconds: 15) {
            let remote = native.remoteDeviceStates?.first { $0.demuxId == primary }
            return remote?.presenting == false && remote?.sharingScreen == false && remote?.videoMuted == true
                && session.activeCall?.stage == .inCall && session.screenCapture == nil
        }
        // Keep the window and the subscription open. A distinct third image makes late delivery
        // distinguishable from frames that the native decoder buffered before Stop.
        screen.showStoppedPattern()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            guard native.localDeviceState.connectionState == .connected, session.activeCall?.stage == .inCall else {
                throw Failure("Call disconnected during the screen-sharing stop check")
            }
            if let (width, height) = native.receiveVideoFrame(demuxId: primary, into: &rgba, maxWidth: 1280, maxHeight: 720),
               ScreenPattern.stopped.matchingSamples(width: width, height: height, rgba: rgba) >= 32 {
                throw Failure("RingRTC received the window's post-stop pattern")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        report("post-stop window update stayed local for four seconds")
    }

    @MainActor static func run(_ session: SignalSession) async throws {
        session.cameraBackend.requestAccess = { false }
        session.start()
        try await wait("linked test account ready", seconds: 90) { session.phase == .ready }
        if CommandLine.arguments.contains("--test-call-link-stdin") {
            defer { session.hangUp() }
            let otherDevice = ProcessInfo.processInfo.environment["SEREIN_TEST_PRESENT_DEVICE"].flatMap(UInt32.init)
            if ProcessInfo.processInfo.environment["SEREIN_TEST_WAIT_FOR_VACANCY"] == "1" {
                try await wait("unrelated account kept the guest in its lobby", seconds: 30) {
                    session.waitingForTestRoom && session.activeCall?.stage == .lobby && session.localCallTestPeerState == .idle
                }
                guard let config = ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_READY"] else { throw Failure("Missing mock configuration") }
                try Data().write(to: URL(fileURLWithPath: config).appendingPathExtension("waiting"), options: .atomic)
            }
            try await wait("automatically joined the unrestricted link from stdin", seconds: 45) {
                if case .failed(let message) = session.localCallTestPeerState { throw Failure(message) }
                return session.activeCall?.stage == .inCall && session.localCallTestPeerState == .running
            }
            guard let id = session.activeCall?.conversationId, let link = session.callLink(id), otherDevice != nil || !link.isAdmin,
                  link.restrictions == CallLinkRestrictions.none.rawValue, !session.callLocalVideo,
                  !session.callLocalAudio else { throw Failure("Guest unexpectedly has admin rights or active capture") }
            try await verifyMedia(session, roomID: id, otherDevice: otherDevice)
            if let otherDevice {
                session.stopLocalCallTestPeer()
                try await wait("only the previously joined device remained", seconds: 25) {
                    session.calling?.groupCall(for: id)?.remoteDeviceStates?.map(\.demuxId) == [otherDevice]
                }
            }
            return
        }
        await session.createCallLink()
        guard case .edit(let roomID) = session.callLinkModal, session.callLink(roomID)?.isAdmin == true else {
            throw Failure("Fixture could not create an owned link")
        }
        session.openCallLinkLobby(roomID, audio: false, video: false)
        guard session.activeCall?.outgoingRing == false else { throw Failure("Unexpected ring setting") }
        session.startCallFromLobby()
        defer { session.hangUp() }
        try await wait("owner joined alone using Swift calling", seconds: 35) {
            let group = session.calling?.groupCall(for: roomID)
            return session.activeCall?.stage == .inCall && group?.localDeviceState.connectionState == .connected
                && group?.localDeviceState.joinState == .joined && group?.remoteDeviceStates?.isEmpty != false
        }
        session.startLocalCallTestPeer()
        try await verifyMedia(session, roomID: roomID)
        try await verifyScreenShare(session, roomID: roomID)
        // A decoded-frame reader may still hold a reference to the old XPC channel when the
        // next peer starts. Release that channel after its replacement has actually joined.
        var retiring = session.calling?.localCallLinkTestPeer?.call
        session.stopLocalCallTestPeer()
        try await wait("stopped peer left the room, owner remained joined", seconds: 24) {
            session.localCallTestPeerState == .idle && session.calling?.groupCall(for: roomID)?.remoteDeviceStates?.isEmpty == true
                && session.activeCall?.stage == .inCall
        }
        session.startLocalCallTestPeer()
        try await wait("replacement peer joined with the previous receiver still draining", seconds: 40) {
            if case .failed(let message) = session.localCallTestPeerState { throw Failure(message) }
            return session.localCallTestPeerState == .running
        }
        withExtendedLifetime(retiring) {}
        retiring = nil
        try await verifyMedia(session, roomID: roomID)
        session.hangUp()
        try await wait("hang up released active peer", seconds: 10) {
            session.activeCall == nil && session.localCallTestPeerState == .idle
        }
        // Hold a new room while the linked device and the independent guest each attempt entry.
        guard let calling = session.calling, let config = ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_READY"] else {
            throw Failure("Missing fixture configuration for the guest room")
        }
        await session.createCallLink()
        guard case .edit(let newID) = session.callLinkModal, newID != roomID,
              let guestRoom = session.callLink(newID) else { throw Failure("Could not create the shared guest room") }
        let state = try await calling.updateCallLinkRestrictions(guestRoom, restrictions: .none)
        guard state.restrictions == .none else { throw Failure("Could not configure the unrestricted room") }
        let shareURL = try CallLinkURL.url(rootKey: guestRoom.rootKey)
        let configURL = URL(fileURLWithPath: config)
        session.openCallLinkLobby(guestRoom.roomId, audio: false, video: false)
        session.startCallFromLobby()
        try await wait("first device joined the unrestricted room", seconds: 35) {
            let group = calling.groupCall(for: guestRoom.roomId)
            return group?.localDeviceState.joinState == .joined && group?.localDeviceState.connectionState == .connected
        }
        guard let demux = calling.groupCall(for: guestRoom.roomId)?.localDeviceState.demuxId else {
            throw Failure("Missing first device's demux ID")
        }
        try Data(String(demux).utf8).write(to: configURL.appendingPathExtension("demux"), options: .atomic)
        try Data(shareURL.utf8).write(to: configURL.appendingPathExtension("guest"), options: .atomic)
        try await wait("test runner requested the room be vacated", seconds: 180) {
            FileManager.default.fileExists(atPath: configURL.appendingPathExtension("done").path)
        }
        session.hangUp()
    }

    @MainActor static func main() async {
        guard ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_READY"] != nil,
              Bundle.main.bundleIdentifier == "org.signalsafe.LocalPeerFixture" else { exit(2) }
        do { try await run(SignalSession()); report("PASS"); exit(0) }
        catch { report("FAIL " + String(describing: error)); exit(1) }
    }
}
