// AxoAlertDialog stories (ts/axo/AxoAlertDialog.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

struct AxoAlertDialogTemplate: View {
    var hiddenTitle = false
    var long = false
    var body: some View {
        PortalStage {
            AxoButton.Root("Open", variant: .subtlePrimary, size: .md)
        } modal: {
            AxoBaseDialog.Host {
                AxoAlertDialog.Content {
                    AxoAlertDialog.Body {
                        AxoAlertDialog.Title(long ? AlertDialogText.exampleTitleLong : AlertDialogText.exampleTitle, screenReaderOnly: hiddenTitle)
                        AxoAlertDialog.Description(long ? AlertDialogText.exampleDescriptionLong : AlertDialogText.exampleDescription)
                    }
                    AxoAlertDialog.Footer {
                        AxoAlertDialog.Cancel(long ? AlertDialogText.exampleCancelLong : nil)
                        AxoAlertDialog.Action(long ? AlertDialogText.exampleActionLong : AlertDialogText.exampleAction, variant: .strongPrimary,
                                              symbol: long ? "check" : nil, arrow: long ? .next : nil) {}
                    }
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoAlertDialogTests {
    @Test(arguments: [("basic", false, false), ("visually-hidden-title", true, false), ("require-explicit-choice", false, false),
                      ("extra-long-text", false, true)], ["light", "dark"])
    func story(story: (String, Bool, Bool), theme: String) throws {
        try Snapshot.assertMatches(AxoAlertDialogTemplate(hiddenTitle: story.1, long: story.2), story: "axo-axoalertdialog--\(story.0)", theme: theme)
    }
}
