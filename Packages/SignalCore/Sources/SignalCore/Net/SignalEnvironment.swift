// Signal's server environments (Desktop config/default.json = staging, production.json):
// the chat service (libsignal Net's environment), storage and CDN hosts, the pinned
// Signal Messenger root CA for HTTPS, and the sealed-sender trust roots. The mock server's
// layout stays in ServiceEndpoints.mockServer.

import Foundation
import LibSignalClient

public enum SignalEnvironment: String, Sendable, CaseIterable {
    case staging, production

    /// libsignal's environment for chat, CDSI, SVR and KT.
    public var netEnvironment: Net.Environment { self == .production ? .production : .staging }

    /// `certificateAuthority` (the same Signal root in both configs).
    public static let signalRootCertificateDER = Data(base64Encoded: "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")!

    public var endpoints: ServiceEndpoints {
        switch self {
        case .staging:
            ServiceEndpoints(storageURL: URL(string: "https://storage-staging.signal.org")!,
                             cdnURLs: [0: URL(string: "https://cdn-staging.signal.org")!, 2: URL(string: "https://cdn2-staging.signal.org")!,
                                       3: URL(string: "https://cdn3-staging.signal.org")!],
                             rootCertificatesDER: [Self.signalRootCertificateDER])
        case .production:
            ServiceEndpoints(storageURL: URL(string: "https://storage.signal.org")!,
                             cdnURLs: [0: URL(string: "https://cdn.signal.org")!, 2: URL(string: "https://cdn2.signal.org")!,
                                       3: URL(string: "https://cdn3.signal.org")!],
                             rootCertificatesDER: [Self.signalRootCertificateDER])
        }
    }

    /// `serverTrustRoots`: the keys sender certificates must chain to.
    public var serverTrustRootsBase64: [String] {
        switch self {
        case .staging: ["BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx", "BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm"]
        case .production: ["BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF", "BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6"]
        }
    }

    public func serverTrustRoots() throws -> [PublicKey] {
        try serverTrustRootsBase64.map { try PublicKey(Data(base64Encoded: $0)!) }
    }

    /// `serverPublicParams` / `genericServerPublicParams` (zkgroup).
    public var serverPublicParams: Data {
        Data(base64Encoded: self == .production ? "AMhf5ywVwITZMsff/eCyudZx9JDmkkkbV6PInzG4p8x3VqVJSFiMvnvlEKWuRob/1eaIetR31IYeAbm0NdOuHH8Qi+Rexi1wLlpzIo1gstHWBfZzy1+qHRV5A4TqPp15YzBPm0WSggW6PbSn+F4lf57VCnHF7p8SvzAA2ZZJPYJURt8X7bbg+H3i+PEjH9DXItNEqs2sNcug37xZQDLm7X36nOoGPs54XsEGzPdEV+itQNGUFEjY6X9Uv+Acuks7NpyGvCoKxGwgKgE5XyJ+nNKlyHHOLb6N1NuHyBrZrgtY/JYJHRooo5CEqYKBqdFnmbTVGEkCvJKxLnjwKWf+fEPoWeQFj5ObDjcKMZf2Jm2Ae69x+ikU5gBXsRmoF94GXTLfN0/vLt98KDPnxwAQL9j5V1jGOY8jQl6MLxEs56cwXN0dqCnImzVH3TZT1cJ8SW1BRX6qIVxEzjsSGx3yxF3suAilPMqGRp4ffyopjMD1JXiKR2RwLKzizUe5e8XyGOy9fplzhw3jVzTRyUZTRSZKkMLWcQ/gv0E4aONNqs4P+NameAZYOD12qRkxosQQP5uux6B2nRyZ7sAV54DgFyLiRcq1FvwKw2EPQdk4HDoePrO/RNUbyNddnM/mMgj4FW65xCoT1LmjrIjsv/Ggdlx46ueczhMgtBunx1/w8k8V+l8LVZ8gAT6wkU5J+DPQalQguMg12Jzug3q4TbdHiGCmD9EunCwOmsLuLJkz6EcSYXtrlDEnAM+hicw7iergYLLlMXpfTdGxJCWJmP4zqUFeTTmsmhsjGBt7NiEB/9pFFEB3pSbf4iiUukw63Eo8Aqnf4iwob6X1QviCWuc8t0LUlT9vALgh/f2DPVOOmR0RW6bgRvc7DSF20V/omg+YBw==" : "ABSY21VckQcbSXVNCGRYJcfWHiAMZmpTtTELcDmxgdFbtp/bWsSxZdMKzfCp8rvIs8ocCU3B37fT3r4Mi5qAemeGeR2X+/YmOGR5ofui7tD5mDQfstAI9i+4WpMtIe8KC3wU5w3Inq3uNWVmoGtpKndsNfwJrCg0Hd9zmObhypUnSkfYn2ooMOOnBpfdanRtrvetZUayDMSC5iSRcXKpdlukrpzzsCIvEwjwQlJYVPOQPj4V0F4UXXBdHSLK05uoPBCQG8G9rYIGedYsClJXnbrgGYG3eMTG5hnx4X4ntARBgELuMWWUEEfSK0mjXg+/2lPmWcTZWR9nkqgQQP0tbzuiPm74H2wMO4u1Wafe+UwyIlIT9L7KLS19Aw8r4sPrXZSSsOZ6s7M1+rTJN0bI5CKY2PX29y5Ok3jSWufIKcgKOnWoP67d5b2du2ZVJjpjfibNIHbT/cegy/sBLoFwtHogVYUewANUAXIaMPyCLRArsKhfJ5wBtTminG/PAvuBdJ70Z/bXVPf8TVsR292zQ65xwvWTejROW6AZX6aqucUjlENAErBme1YHmOSpU6tr6doJ66dPzVAWIanmO/5mgjNEDeK7DDqQdB1xd03HT2Qs2TxY3kCK8aAb/0iM0HQiXjxZ9HIgYhbtvGEnDKW5ILSUydqH/KBhW4Pb0jZWnqN/YgbWDKeJxnDbYcUob5ZY5Lt5ZCMKuaGUvCJRrCtuugSMaqjowCGRempsDdJEt+cMaalhZ6gczklJB/IbdwENW9KeVFPoFNFzhxWUIS5ML9riVYhAtE6JE5jX0xiHNVIIPthb458cfA8daR0nYfYAUKogQArm0iBezOO+mPk5vCNWI+wwkyFCqNDXz/qxl1gAntuCJtSfq9OC3NkdhQlgYQ==")!
    }
    public var genericServerPublicParams: Data {
        Data(base64Encoded: self == .production ? "AeCO67P9mIv1yUHkdeZ9JF789GDbox61GvTqq3S4kYc1ADUWxWHQygU390tv1oRWt9WjkdZlU7mKkifF59ftjE+2ZlMmxns6I+ySiLpR8FEmfu+TGpVp3zYTjNV93obJJTyBCCsSHVETCyQRbKdCyb5TMa6LGrvcZaX0Q/VAavhuNA/m4kSiRMgSnYrUjGhVekdDnF+7xioo4wvFnxjIDh7uJQrYOWD6MloNGX7St5gbysTuQQ7i/HI38b9V8x8mKazuDSXxB//BKGZx/XHkK8cHX+QK1MPxYUVM1/CBI5oW" : "AYhaw+NbxtNLo/RlGFEsHd904hW38LpPJ59jYJlNmT4wwtyOq4xzCs/MyXsfRbIsAYhQjDnpE0rhFtWkMcn/kV740SISwFfpPHunrtZ9h0YWz5QNNbI5I3DRGUjhKXgMU7J7s7qOr0fdms+g0e+L9FMSjJLobDkOngp/m0B5TsxTyqLscJ5VyU69Cj8txImTfHMCKrYphYfRHO78RwPoz2g2tGUAzEbKHm12OgDna2qutkE5TvYqwZczvgZyLVHdHXpvdyOlEdv4afVyWkI7u/S0XYDonIJoHlxqJoTSepZR")!
    }

    /// `sfuUrl`
    public var sfuURL: URL { URL(string: self == .production ? "https://sfu.voip.signal.org/" : "https://sfu.staging.voip.signal.org/")! }

    public func net(userAgent: String) -> Net {
        Net(env: netEnvironment, userAgent: userAgent, buildVariant: .production)
    }
}
