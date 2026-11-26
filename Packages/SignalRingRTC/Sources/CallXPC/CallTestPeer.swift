// QA and debug builds only (Package.swift `testPeer`; SEREIN_QA_CALL_PEER=1 Tools/build-app.sh).
#if SEREIN_CALL_TEST_PEER
import Foundation
import MediaXPCInterface
import SignalRingRTC

extension RemoteCallEndpoint {
    /// Only test bundles staged with Tools/stage-call-test-peer.py contain this service.
    public static func testPeerFactory() -> RingRTCEndpointFactory? {
        #if os(Linux)
        // This optional QA fixture is an XPC service inside the macOS test bundle.
        return nil
        #else
        let bundle = Bundle.main
        let url = bundle.bundleURL.appendingPathComponent("Contents/XPCServices/SignalCallTestPeer.xpc")
        guard let host = bundle.bundleIdentifier,
              let peers = bundle.object(forInfoDictionaryKey: XPCPeer.infoKey) as? [String: String],
              peers["app"] == host else { return nil }
        let identifier = host + ".call-test-peer"
        guard Bundle(url: url)?.bundleIdentifier == identifier else { return nil }
        let peer = XPCPeer.requirement(identifier: identifier,
                                       sameTeam: bundle.object(forInfoDictionaryKey: XPCPeer.sameTeamKey) as? Bool ?? false)
        return factory(.service(identifier), peer: peer)
        #endif
    }
}

/// Eight color bars with a bright marker that travels across them at ten frames per second.
public enum CallTestPeerVideo {
    public static let width = 320
    public static let height = 240

    private static let background: [UInt8] = {
        let luma: [UInt8] = [180, 162, 131, 112, 84, 65, 35, 16]
        let cb: [UInt8] = [128, 44, 156, 72, 184, 100, 212, 128]
        let cr: [UInt8] = [128, 142, 44, 58, 198, 212, 114, 128]
        var pixels: [UInt8] = []
        for (plane, columns, rows) in [(luma, width, height), (cb, width / 2, height / 2), (cr, width / 2, height / 2)] {
            let row = (0..<columns).map { plane[$0 * plane.count / columns] }
            for _ in 0..<rows { pixels.append(contentsOf: row) }
        }
        return pixels
    }()

    /// One packed I420 image. The entire marker stays in frame as it reverses direction.
    public static func frame(_ index: Int) -> [UInt8] {
        var pixels = background
        let travel = width - 32
        let phase = abs(index % (travel / 2)) * 4
        let left = min(phase, 2 * travel - phase)
        for y in (height / 2 - 16)..<(height / 2 + 16) {
            for x in left..<(left + 32) {
                let edge = x < left + 3 || x >= left + 29 || abs(y - height / 2) >= 13
                pixels[y * width + x] = edge ? 16 : 235
            }
        }
        let chromaSize = width * height / 4
        for y in (height / 4 - 8)..<(height / 4 + 8) {
            for x in (left / 2)..<(left / 2 + 16) {
                let offset = width * height + y * (width / 2) + x
                pixels[offset] = 128
                pixels[offset + chromaSize] = 128
            }
        }
        return pixels
    }
}
#endif
