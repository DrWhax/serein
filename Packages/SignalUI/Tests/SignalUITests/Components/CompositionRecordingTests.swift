// ts/components/CompositionRecording.dom.stories.tsx (Visible; Default is an "Activate"
// button harness) and DiscardDraftDialog.dom.stories.tsx.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CompositionRecordingTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let now = TimelineMessageTests.now
        let peaks = (0..<200).map { RecordingPeak(value: Double($0) / 50 - Double($0 / 50), index: $0) }
        try Snapshot.assertMatches(TimelineMessageTests.stage(CompositionRecording(peaks: peaks, startedAt: now)),
                                   story: "components-compositionrecording--visible", theme: theme)
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { DiscardDraftDialog() } },
                                   story: "components-discarddraftdialog--default", theme: theme)
    }
}
