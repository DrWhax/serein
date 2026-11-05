// Port of ts/components/ClearingData.dom.tsx (stylesheets/components/ClearingData.scss, with
// InstallScreenBackupImportStep's content styles): the full-window "deleting data" screen —
// the Signal logo, then centred below a 64px top margin the step's title (font-title-2), an
// indeterminate 326px progress bar and a caption. `deleteAllData` reports the step; until it
// does, the title and caption are empty.

import SignalI18n
import SwiftUI

public struct ClearingData: View {
    /// `StateType`
    public enum Step: Sendable { case leavingGroups, deletingAccount, deletingData }

    let step: Step?
    @Environment(\.i18n) var i18n
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    @Environment(\.layoutDirection) var direction

    public init(step: Step?) { self.step = step }

    var texts: (String, String) {
        switch step {
        case nil: ("", "")
        case .leavingGroups: (i18n("icu:DeletingAccount__LeavingGroups__Title"), i18n("icu:DeletingAccount__LeavingGroups__Detail"))
        case .deletingAccount: (i18n("icu:DeletingAccount__DeletingData__Title"), i18n("icu:DeletingAccount__DeletingData__Detail"))
        case .deletingData: (i18n("icu:deleteAllDataProgress"), i18n("icu:ClearingData__description"))
        }
    }

    public var body: some View {
        let (title, description) = texts
        ZStack {
            VStack(spacing: 0) {
                // h3.InstallScreenBackupImportStep__title: margin-block 0 20px (an empty h3 has no line box)
                if !title.isEmpty {
                    CSSText(title, style: LegacyType.title2(), alignment: .center, color: .labelPrimary).padding(.bottom, 20)
                }
                ProgressBar(fractionComplete: nil, isRTL: direction == .rightToLeft)
                    .frame(width: 326)
                    .padding(.bottom, 18)
                if !description.isEmpty {
                    CSSText(description, style: LegacyType.caption(), alignment: .center,
                            color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 64 + dragAreaHeight)
            InstallScreenSignalLogo()
        }
        .overlay(alignment: .top) { TitlebarDragArea() }
        .accessibilityElement(children: .combine)
    }
}
