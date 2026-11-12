// ringrtc's HTTP requests (it runs in the calling service) go out through the app only to the
// SFU (CallingService.isSFU).

import Foundation
import Testing
@testable import SignalCore

struct CallingSFUTests {
    @Test func onlyTheSFU() {
        let sfu = URL(string: "https://sfu.voip.signal.org")!
        let ok = ["https://sfu.voip.signal.org/v2/conference/participants", "https://SFU.voip.signal.org/v1/call-link?x=1",
                  "https://sfu.voip.signal.org"]
        let refused = ["https://sfu.voip.signal.org.evil.example/v2/conference", "http://sfu.voip.signal.org/v2", "https://sfu.voip.signal.org:8443/v2",
                       "https://user@sfu.voip.signal.org/v2", "https://chat.signal.org/v1/accounts", "file:///etc/hosts", "https://127.0.0.1/v2"]
        for u in ok { #expect(CallingService.isSFU(URL(string: u)!, sfu), "\(u)") }
        for u in refused { #expect(!CallingService.isSFU(URL(string: u)!, sfu), "\(u)") }
        let mock = URL(string: "https://localhost:9999/callingService")!
        #expect(CallingService.isSFU(URL(string: "https://localhost:9999/callingService/v2/conference/participants")!, mock))
        #expect(!CallingService.isSFU(URL(string: "https://localhost:9999/callingServiceX/v2")!, mock))
        #expect(!CallingService.isSFU(URL(string: "https://localhost:9999/v1/messages")!, mock))
    }
}
