// CallQualitySurveyDialog: the one story (the first page), plus the issue picker's rules.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallQualitySurveyDialogTests {
    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        try Snapshot.assertMatches(SmallDialogsTests.modal(CallQualitySurveyDialog()), story: "components-callqualitysurveydialog--default", theme: theme)
    }

    @Test func issueGroups() {
        var d = CallQualitySurveyDialog()
        // (State outside a view keeps its initial value: exercise the pure rules.)
        #expect(CallQualityIssue.groups.map(\.parent) == [.audio, .video, .callDropped, .other])
        #expect(CallQualityIssue.audioLocalEcho.labelKey == "icu:CallQualitySurvey__Issue--AUDIO_LOCAL_ECHO")
        #expect(CallQualityIssue.callDropped.symbol == "x-circle")
        d.userHasSeenOtherForm = false
        #expect(d.canContinue == false && d.isOtherInputValid)
    }
}
