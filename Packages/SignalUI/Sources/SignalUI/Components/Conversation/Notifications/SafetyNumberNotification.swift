// SafetyNumberNotification (ts/components/conversation/SafetyNumberNotification.dom.tsx):
// "Your safety number with {name} has changed." and a small system-message "View" button.

import SignalI18n
import SwiftUI

public struct SafetyNumberNotification: View {
    let contactTitle: String
    let toggleSafetyNumberModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(contactTitle: String, toggleSafetyNumberModal: @escaping () -> Void) {
        self.contactTitle = contactTitle
        self.toggleSafetyNumberModal = toggleSafetyNumberModal
    }

    public var body: some View {
        SystemMessage(.icon("v3/safety_number/safety_number-compact"),
                      contents: CSSTextRun.runs(i18n.richText("icu:safetyNumberChangedGroup", ["name": .element("name")]),
                                                elements: ["name": Emojify.run(contactTitle)])) {
            LegacyButton(i18n("icu:SafetyNumberNotification__viewSafetyNumber"), size: .small, variant: .systemMessage,
                         action: toggleSafetyNumberModal)
        }
    }
}
