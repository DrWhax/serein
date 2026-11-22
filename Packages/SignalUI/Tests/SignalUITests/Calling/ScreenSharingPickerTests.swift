import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
@testable import SignalUI

@MainActor struct ScreenSharingPickerTests {
    @Test func receivesOriginalFilterFromBackgroundCallback() async throws {
        let picker = SystemScreenPicker()
        let original = Mutex<ObjectIdentifier?>(nil)
        var dismissals = 0
        let selected = try await picker.selection(present: {
            DispatchQueue.global().async {
                let filter = SCContentFilter()
                original.withLock { $0 = ObjectIdentifier(filter) }
                picker.contentSharingPicker(.shared, didUpdateWith: filter, for: nil)
            }
        }, dismiss: { dismissals += 1 })
        let filter = try #require(selected)
        #expect(ObjectIdentifier(filter) == original.withLock { $0 })
        #expect(dismissals == 1)
    }
}
