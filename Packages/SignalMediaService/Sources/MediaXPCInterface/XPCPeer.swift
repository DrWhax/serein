// Who may talk to whom over XPC. Tools/build-app.sh writes each component's code-signing
// requirement into every bundle's Info.plist (`SereinXPCPeers`): the bundle identifier, and
// with a signing identity its Team ID under an Apple anchor. Each connection is restricted
// to the requirement of the peer it expects (NSXPCConnection.setCodeSigningRequirement, on
// the client and on every accepted connection), so the system invalidates a connection from
// or to anything else before a message is delivered. A bundled service without the key
// refuses to start; in-process listeners (tests) have no requirement.

import Foundation

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

    public static let infoKey = "SereinXPCPeers"

    /// The requirement for `peer`, from this bundle's Info.plist (nil outside a built bundle).
    public static func requirement(_ peer: XPCPeer, bundle: Bundle = .main) -> String? {
        (bundle.object(forInfoDictionaryKey: infoKey) as? [String: String])?[peer.rawValue]
    }

    /// For a bundled service: the requirement its clients must meet, or exit before serving.
    public static func required(_ peer: XPCPeer, by service: String) -> String {
        guard let r = requirement(peer), !r.isEmpty else {
            FileHandle.standardError.write(Data("\(service): no code-signing requirement for \(peer.rawValue), exiting\n".utf8))
            exit(78)
        }
        return r
    }
}
