import Foundation
import Testing
@testable import SignalCore

@Suite struct HTTPClientTests {
    /// The app's ATS exceptions would allow http:// to Signal hosts; the client never sends it.
    @Test func refusesPlainHTTP() async {
        let client = HTTPClient(rootCertificatesDER: [SignalEnvironment.signalRootCertificateDER])
        await #expect(throws: HTTPError.insecureURL) { try await client.send("GET", URL(string: "http://storage.signal.org/v1/storage/manifest")!) }
        await #expect(throws: HTTPError.insecureURL) {
            try await client.sendWithHeaders("GET", URL(string: "http://cdn.signal.org/attachments/x")!)
        }
    }
}
