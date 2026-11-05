// Port of ts/components/preferences/LinkedDevicesOnboardingDialog.dom.tsx: what a linked
// device is, and three bullets on how linking works.

import SignalI18n
import SwiftUI

public struct LinkedDevicesOnboardingDialog: View {
    let onDismiss: () -> Void
    @Environment(\.i18n) var i18n

    public init(onDismiss: @escaping () -> Void = {}) { self.onDismiss = onDismiss }

    /// An `li` of `list-disc ps-4`: Chromium's disc marker (4px) 13px before the text, on the
    /// first line.
    func bullet(_ key: String) -> some View {
        CSSText(i18n(key), type: .bodyMedium, color: .labelPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { Circle().fill(AxoColor.labelPrimary).frame(width: 4, height: 4).offset(x: -15, y: 8) }
            .padding(.leading, 16)
            .padding(.top, 12)
    }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false) {
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    AxoSymbol.Icon("device-phone-laptop", size: 24, label: nil).cssTextColor(.labelAccent)
                        .padding(12).background(Circle().fill(AxoColor.fillAccentTint))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                    CSSText(runs: CSSTextRun.runs(i18n.richText("icu:LinkedDevicesOnboardingDialog__description"), tags: ["bold": .bold]),
                            style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary)
                    bullet("icu:LinkedDevicesOnboardingDialog__bullet--1")
                    bullet("icu:LinkedDevicesOnboardingDialog__bullet--2")
                    bullet("icu:LinkedDevicesOnboardingDialog__bullet--3--2")
                }
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) { AxoDialog.Close(action: onDismiss) }
        }
    }
}
