// ts/components/conversation/pinned-messages/PinMessageDialog.dom.stories.tsx: with the maximum
// pinned, the dialog opens on "Replace oldest pin?".

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PinMessageDialogTests {
    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host { PinMessageDialog(hasMaxPinnedMessages: true, isPinningDisappearingMessage: true, seenWarningCount: 0) }
        }
        try Snapshot.assertMatches(view, story: "components-pinnedmessages-pinmessagedialog--default", theme: theme)
    }
}
