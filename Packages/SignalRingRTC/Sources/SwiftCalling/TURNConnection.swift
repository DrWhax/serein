import Foundation
import Network
import Security

enum TURNConnection: Sendable {
    case socket(NWConnection, stream: Bool)
    case tls(URLSession, URLSessionStreamTask)

    init(server: TURNServerEndpoint, dialHostname: Bool, trustAnchor: SecCertificate?) {
        if server.transport == .udp {
            self = .socket(NWConnection(to: server.address, using: .udp), stream: false)
            return
        }

        if server.transport == .tcp {
            let options = NWProtocolTCP.Options()
            options.noDelay = true
            self = .socket(NWConnection(to: server.address, using: NWParameters(tls: nil, tcp: options)), stream: true)
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        // Signal can supply a numeric route and an independent DNS identity. Bind the
        // certificate to that identity even when DNS is unavailable. On a named retry
        // Foundation also sends the TLS server-name extension for virtual hosting.
        let identity = server.tlsHostname ?? server.host
        let destination = dialHostname ? identity : server.host
        let delegate = identity != destination || trustAnchor != nil ? TURNPeerTrust(identity: identity, anchor: trustAnchor) : nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.streamTask(withHostName: destination, port: Int(server.port.rawValue))
        task.startSecureConnection()
        self = .tls(session, task)
    }

    var networkPath: NWPath? {
        if case .socket(let connection, _) = self { return connection.currentPath }
        return nil
    }

    var isStream: Bool {
        if case .socket(_, let stream) = self { return stream }
        return true
    }

    func start() {
        switch self {
        case .socket(let connection, _): connection.start(queue: DispatchQueue(label: "org.serein.turn"))
        case .tls(_, let task): task.resume()
        }
    }

    func read(_ complete: @escaping @Sendable (Data?, Bool) -> Void) {
        switch self {
        case .socket(let connection, stream: true):
            connection.receive(minimumIncompleteLength: 1, maximumLength: TURNStreamFramer.chunkSize) { bytes, _, eof, error in
                complete(bytes, eof || error != nil)
            }
        case .socket(let connection, stream: false):
            connection.receiveMessage { bytes, _, _, error in complete(bytes, error != nil) }
        case .tls(_, let task):
            task.readData(ofMinLength: 1, maxLength: TURNStreamFramer.chunkSize, timeout: 0) { bytes, eof, error in
                complete(bytes, eof || error != nil)
            }
        }
    }

    func send(_ bytes: Data, completion: @escaping @Sendable (Bool) -> Void) {
        switch self {
        case .socket(let connection, _):
            connection.send(content: bytes, completion: .contentProcessed { completion($0 == nil) })
        case .tls(_, let task):
            task.write(bytes, timeout: 15) { completion($0 == nil) }
        }
    }

    func cancel() {
        switch self {
        case .socket(let connection, _): connection.cancel()
        case .tls(let session, let task):
            task.cancel()
            session.invalidateAndCancel()
        }
    }
}

/// Scope verification to the authenticated relay name. An isolated test can provide its own
/// root certificate; the calling service always verifies against platform trust anchors.
private final class TURNPeerTrust: NSObject, URLSessionTaskDelegate {
    let identity: String
    let anchor: SecCertificate?

    init(identity: String, anchor: SecCertificate?) {
        self.identity = identity
        self.anchor = anchor
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) { verify(challenge) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) { verify(challenge) }

    private func verify(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, identity as CFString)) == errSecSuccess
        else { return (.cancelAuthenticationChallenge, nil) }
        if let anchor {
            guard SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return (.cancelAuthenticationChallenge, nil) }
        }
        guard SecTrustEvaluateWithError(trust, nil)
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
