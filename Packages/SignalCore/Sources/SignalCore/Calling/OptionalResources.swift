// OptionalResourceService (app/OptionalResourceService.main.ts): large resources that are
// not bundled, fetched once from updates2.signal.org, checked against the size and SHA-512
// from the build's optional-resources.json, and cached on disk. A cached file that no
// longer matches is fetched again; a download that does not match is rejected.

import CryptoKit
import Foundation

public struct OptionalResource: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var size: Int
    /// Base64 SHA-512.
    public var digest: String

    /// The Opus DRED / deep PLC weights ringrtc loads as the "opus-dred" asset
    /// (`prepareCallingAssets`, calling-dred_weights-*.bin).
    public static let callingDredWeights = OptionalResource(
        name: "calling-dred_weights-1_6_1-f4aed08a.bin",
        url: URL(string: "https://updates2.signal.org/static/android/calling/deep_plc-dred_weights-1_6_1-f4aed08a.bin")!,
        size: 1_998_208,
        digest: "sdfpdb/u3wiTfBr2s0gx1LJX6jii4tquyax/UBThTGWTEXyOCSKjYmYV+9tKQZcO+Q1B1ReoGSW3VbvzeMGKaQ==")

    public init(name: String, url: URL, size: Int, digest: String) {
        self.name = name
        self.url = url
        self.size = size
        self.digest = digest
    }

    /// Size and digest both match (the digest comparison is constant-time).
    public func matches(_ data: Data) -> Bool {
        guard data.count == size, let expected = Data(base64Encoded: digest), expected.count == 64 else { return false }
        let actual = Data(SHA512.hash(data: data))
        var diff: UInt8 = 0
        for (a, b) in zip(actual, expected) { diff |= a ^ b }
        return diff == 0
    }
}

public enum OptionalResourceError: Error, Equatable {
    case invalidRemoteResource(String)
    case badStatus(Int)
}

public actor OptionalResources {
    let directory: URL
    let session: URLSession
    var cache: [String: Data] = [:]

    /// `directory` is the app's optional-resources cache (userData/optional-resources upstream).
    public init(directory: URL) {
        self.directory = directory
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    /// `getData`: memory cache, then disk (re-verified), then the network.
    public func data(for resource: OptionalResource) async throws -> Data {
        if let d = cache[resource.name] { return d }
        let path = directory.appendingPathComponent(resource.name)
        if let onDisk = try? Data(contentsOf: path), resource.matches(onDisk) {
            cache[resource.name] = onDisk
            return onDisk
        }
        let (data, response) = try await session.data(from: resource.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw OptionalResourceError.badStatus(http.statusCode) }
        guard resource.matches(data) else { throw OptionalResourceError.invalidRemoteResource(resource.name) }
        cache[resource.name] = data
        // A failed write still returns the verified data.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
        return data
    }
}

extension CallingService {
    /// `prepareCallingAssets`: the DRED weights, registered with ringrtc as "opus-dred".
    public func prepareCallingAssets(_ resources: OptionalResources) async throws {
        let weights = try await resources.data(for: .callingDredWeights)
        try rtc.addAsset("opus-dred", content: weights)
    }

    /// Routes the receive pipeline's calling events (`handleCallingMessage`, history syncs).
    public func handle(_ event: ReceiveEvent) async {
        switch event {
        case .callMessage(let m): await handleCallingMessage(m)
        case .callHistoryChanged: emit(.historyChanged)
        default: break
        }
    }
}
