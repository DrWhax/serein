// The storage service's group endpoints (WebAPI STORAGE_CALLS groups*, createGroup, getGroup,
// getGroupLog, modifyGroup, getGroupFromLink, uploadGroupAvatar/getGroupAvatar), each with the
// zkgroup presentation for the group as Basic auth.

import Foundation
import SignalProtos
import SwiftProtobuf

public enum GroupsAPIError: Error, Equatable {
    case badAvatarForm
}

public struct GroupLogPage: Sendable {
    public var changes: Signalservice_GroupChanges
    /// `Content-Range: versions <start>-<end>/<current>` on a 206.
    public var range: (start: Int, end: Int, current: Int)?
}

public struct GroupsAPI: Sendable {
    /// `SUPPORTED_CHANGE_EPOCH` (GroupTerminateChangeUpdate).
    public static let supportedChangeEpoch = 7

    let http: HTTPClient
    let endpoints: ServiceEndpoints
    let credentials: GroupCredentials

    public init(http: HTTPClient, endpoints: ServiceEndpoints, credentials: GroupCredentials) {
        self.http = http
        self.endpoints = endpoints
        self.credentials = credentials
    }

    func url(_ path: String) -> URL { URL(string: endpoints.storageURL.absoluteString + path)! }

    func request(_ method: String, _ path: String, keys: GroupKeys, body: Data? = nil, headers extra: [String: String] = [:],
                 accept: Set<Int> = []) async throws -> (status: Int, body: Data, headers: [String: String]) {
        var headers = extra
        headers["Authorization"] = try await credentials.authorization(for: keys.secret())
        headers["Content-Type"] = "application/x-protobuf"
        return try await http.sendWithHeaders(method, url(path), body: body, headers: headers, accept: accept)
    }

    /// `getGroup`
    public func fetch(_ keys: GroupKeys) async throws -> Signalservice_GroupResponse {
        try Signalservice_GroupResponse(serializedBytes: try await request("GET", "/v2/groups", keys: keys).body)
    }

    /// `groupJoinedAtVersion`
    public func joinedAtVersion(_ keys: GroupKeys) async throws -> Int {
        Int(try Signalservice_Member(serializedBytes: try await request("GET", "/v2/groups/joined_at_version", keys: keys).body).joinedAtVersion)
    }

    /// `getGroupLog` (one page).
    public func logs(_ keys: GroupKeys, from start: Int, includeFirstState: Bool, includeLastState: Bool,
                     cachedEndorsementsExpiration: Int64 = 0) async throws -> GroupLogPage {
        let r = try await request("GET", "/v2/groups/logs/\(start)?includeFirstState=\(includeFirstState)&includeLastState=\(includeLastState)"
                                  + "&maxSupportedChangeEpoch=\(Self.supportedChangeEpoch)", keys: keys,
                                  headers: ["Cached-Send-Endorsements": String(cachedEndorsementsExpiration)], accept: [206])
        let changes = try Signalservice_GroupChanges(serializedBytes: r.body)
        var range: (Int, Int, Int)? = nil
        if r.status == 206, let header = r.headers["content-range"] { range = Self.parseRange(header) }
        return GroupLogPage(changes: changes, range: range)
    }

    /// `PARSE_GROUP_LOG_RANGE_HEADER`: `versions <start>-<end>/<current>`.
    static func parseRange(_ header: String) -> (Int, Int, Int)? {
        guard header.hasPrefix("versions") else { return nil }
        let rest = header.dropFirst("versions".count).drop { $0 == " " || $0 == "\t" }
        let parts = rest.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count >= 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2].prefix { $0.isNumber }),
              parts[0].count <= 10, parts[1].count <= 10 else { return nil }
        return (a, b, c)
    }

    /// `createGroup`
    public func create(_ group: Signalservice_Group, keys: GroupKeys) async throws -> Signalservice_GroupResponse {
        try Signalservice_GroupResponse(serializedBytes: try await request("PUT", "/v2/groups", keys: keys, body: group.serializedData()).body)
    }

    /// `modifyGroup`; a join via link passes the link's password.
    public func modify(_ actions: Signalservice_GroupChange.Actions, keys: GroupKeys, inviteLinkPassword: Data? = nil) async throws
        -> Signalservice_GroupChangeResponse
    {
        let query = inviteLinkPassword.map { "?inviteLinkPassword=" + Self.webSafe($0) } ?? ""
        return try Signalservice_GroupChangeResponse(serializedBytes: try await request("PATCH", "/v2/groups" + query, keys: keys,
                                                                                        body: actions.serializedData()).body)
    }

    /// `getExternalGroupCredential` (`fetchMembershipProof`): the token that proves membership to
    /// the calling SFU, as its UTF-8 bytes.
    public func membershipProof(_ keys: GroupKeys) async throws -> Data {
        Data(try Signalservice_ExternalGroupCredential(serializedBytes: try await request("GET", "/v2/groups/token", keys: keys).body).token.utf8)
    }

    /// `getGroupFromLink`
    public func joinInfo(_ keys: GroupKeys, inviteLinkPassword: Data?) async throws -> Signalservice_GroupJoinInfo {
        try Signalservice_GroupJoinInfo(serializedBytes: try await request("GET", "/v2/groups/join/" + (inviteLinkPassword.map(Self.webSafe) ?? ""),
                                                                           keys: keys).body)
    }

    /// `toWebSafeBase64`
    static func webSafe(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// `getGroupAvatar` (CDN 0).
    public func avatar(_ key: String) async throws -> Data {
        var client = http
        client.maxResponseBytes = 5 << 20
        let path = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? key
        return try await client.send("GET", URL(string: endpoints.cdnURLs[0]!.absoluteString + "/" + path)!).body
    }

    /// `uploadGroupAvatar`: an upload form from the storage service, then an S3-style POST.
    public func uploadAvatar(_ encrypted: Data, keys: GroupKeys) async throws -> String {
        let form = try Signalservice_AvatarUploadAttributes(serializedBytes: try await request("GET", "/v2/groups/avatar/form", keys: keys).body)
        guard !form.key.isEmpty, !form.credential.isEmpty, !form.acl.isEmpty, !form.algorithm.isEmpty, !form.date.isEmpty, !form.policy.isEmpty,
              !form.signature.isEmpty else { throw GroupsAPIError.badAvatarForm }
        let (body, contentType) = Self.multipart(form, file: encrypted, boundary: "----------------" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        _ = try await http.send("POST", URL(string: endpoints.cdnURLs[0]!.absoluteString + "/")!, body: body,
                                headers: ["Content-Type": contentType, "Content-Length": String(body.count)])
        return form.key
    }

    /// `makePutParams`
    static func multipart(_ f: Signalservice_AvatarUploadAttributes, file: Data, boundary: String) -> (Data, String) {
        let crlf = "\r\n"
        func section(_ name: String, _ value: String) -> String { ["--\(boundary)", "Content-Disposition: form-data; name=\"\(name)\"\(crlf)", value].joined(separator: crlf) }
        let start = [
            section("key", f.key), section("x-amz-credential", f.credential), section("acl", f.acl), section("x-amz-algorithm", f.algorithm),
            section("x-amz-date", f.date), section("policy", f.policy), section("x-amz-signature", f.signature),
            section("Content-Type", "application/octet-stream"),
            "--\(boundary)", "Content-Disposition: form-data; name=\"file\"", "Content-Type: application/octet-stream\(crlf)\(crlf)",
        ].joined(separator: crlf)
        let end = "\(crlf)--\(boundary)--\(crlf)"
        return (Data(start.utf8) + file + Data(end.utf8), "multipart/form-data; boundary=\(boundary)")
    }
}
