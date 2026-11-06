// CallLinkDetails stories (FAKE_CALL_LINK / FAKE_CALL_LINK_WITH_ADMIN_KEY, and
// getFakeCallLinkHistoryGroup: calls now, 30, 45 and 60 minutes ago; captured at about noon).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallLinkDetailsTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_610)     // 2026-11-04 12:00:10 GMT
    static let history = CallHistoryGroup(type: .adhoc, direction: .incoming, status: .joined, timestamp: now,
                                          children: [0, 30, 45, 60].map { .init(callId: "\($0)", timestamp: now.addingTimeInterval(-Double($0) * 60)) })
    nonisolated static let admin = CallLinkInfo(name: "Admin Link", rootKey: "bpmc-mrgn-hntf-mffd-mndd-xbxk-zmgq-qszg", isAdmin: true)
    nonisolated static let fun = CallLinkInfo(name: "Fun Link", rootKey: "dxbb-xfqz-xkgp-nmrx-bpqn-ptkb-spdt-pdgt", isAdmin: false)

    @Test(arguments: [
        ("admin", admin, false, false, false, false), ("admin-and-call-active", admin, true, true, false, false),
        ("admin-and-in-call", admin, true, true, true, false), ("admin-recently-ended-call", admin, false, true, false, false),
        ("non-admin", fun, false, false, false, false), ("non-admin-and-call-active", fun, true, true, false, false),
        ("in-another-call", fun, false, true, false, true), ("in-another-call-and-call-active", fun, true, true, false, true),
        ("missing-call-link", nil, false, false, false, false),
    ] as [(String, CallLinkInfo?, Bool, Bool, Bool, Bool)], ["light", "dark"])
    func story(_ s: (String, CallLinkInfo?, Bool, Bool, Bool, Bool), theme: String) throws {
        let view = CallLinkDetails(callLink: s.1, callHistoryGroup: Self.history, isAnybodyInCall: s.2, isCallActiveOnServer: s.3, isInCall: s.4,
                                   isInAnotherCall: s.5)
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now).environment(\.timeZone, TimeZone(identifier: "GMT")!),
                                   story: "components-calllinkdetails--\(s.0)", theme: theme)
    }
}
