// Who may talk to whom over XPC. Tools/build-app.sh writes each component's signing identifier
// into every bundle's Info.plist (`SereinXPCPeers`), and with a signing identity
// `SereinXPCSameTeam`. A peer must then carry the identifier and be signed by this process's
// team with an Apple-issued certificate (XPCPeerRequirement.isFromSameTeam); ad-hoc signatures
// have no Team ID, so there only the identifier can be required (a lightweight code
// requirement). Services require it of every session on their listener, the app's channels of
// every session they open (XPCTransport.swift), so the system ends a session from or to
// anything else before a message is delivered. A bundled service without the key refuses to
// start; in-process listeners (tests) have no requirement.

import Foundation
import XPC

public enum XPCPeer: String, Sendable, CaseIterable {
    /// Serein.app.
    case app
    /// SignalMediaDecoder.xpc.
    case decoder
    /// SignalLinkPreviewParser.xpc.
    case parser
    /// SignalLinkPreviewFetcher.xpc.
    case fetcher
    /// SignalGifSearch.xpc.
    case gifs
    /// SignalVoiceNoteEncoder.xpc.
    case voice
    /// SignalCalling.xpc.
    case calling

    public static let infoKey = "SereinXPCPeers"
    public static let sameTeamKey = "SereinXPCSameTeam"

    /// The requirement for `peer`, from this bundle's Info.plist (nil outside a built bundle).
    public static func requirement(_ peer: XPCPeer, bundle: Bundle = .main) -> XPCPeerRequirement? {
        guard let identifier = (bundle.object(forInfoDictionaryKey: infoKey) as? [String: String])?[peer.rawValue], !identifier.isEmpty else { return nil }
        return requirement(identifier: identifier, sameTeam: bundle.object(forInfoDictionaryKey: sameTeamKey) as? Bool ?? false)
    }

    /// A peer signed with `identifier`, and with `sameTeam` by this process's team.
    public static func requirement(identifier: String, sameTeam: Bool) -> XPCPeerRequirement {
        sameTeam ? .isFromSameTeam(andMatchesSigningIdentifier: identifier)
            : XPCPeerRequirement(lightweightCodeRequirements: ["signing-identifier": XPCLiteralValue(identifier)])
    }

    /// For a bundled service: the requirement its clients must meet, or exit before serving.
    public static func required(_ peer: XPCPeer, by service: String) -> XPCPeerRequirement {
        guard let r = requirement(peer) else {
            FileHandle.standardError.write(Data("\(service): no code-signing requirement for \(peer.rawValue), exiting\n".utf8))
            exit(78)
        }
        return r
    }
}
