// Port of ts/components/CallDiagnosticWindow.dom.tsx: the call's diagnostic info (shown from
// the call quality survey) as pretty-printed JSON, with the raw WebRTC stats expanded from
// their text form, and a Close button.

import Foundation
import SignalI18n
import SwiftUI

public struct CallDiagnosticWindow: View {
    let diagnosticData: String
    let closeWindow: () -> Void
    @Environment(\.i18n) var i18n

    public init(diagnosticData: String, closeWindow: @escaping () -> Void) {
        self.diagnosticData = diagnosticData
        self.closeWindow = closeWindow
    }

    /// `{ rawStats, rawStatsText, ...rest }` → `{ ...rest, rawStats: JSON.parse(rawStatsText) }`,
    /// indented by two; the data as given when it is not that shape. (JSONSerialization does
    /// not keep key order: keys come out sorted.)
    static func format(_ data: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              let rawText = object["rawStatsText"] as? String,
              let raw = try? JSONSerialization.jsonObject(with: Data(rawText.utf8), options: [.fragmentsAllowed]) else { return data }
        object["rawStatsText"] = nil
        object["rawStats"] = raw
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return data }
        return text
    }

    public var body: some View {
        let formatted = Self.format(diagnosticData)
        VStack(alignment: .leading, spacing: 0) {
            CSSText(i18n("icu:CallDiagnosticWindow__title"), type: .titleMedium, color: .labelPrimary)
                .padding(.bottom, 16)
            ScrollView {
                Text(formatted)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AxoColor.labelPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(AxoColor.surfaceSecondary)
            .overlay(Rectangle().strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
            .frame(maxHeight: .infinity)
            HStack {
                Spacer(minLength: 0)
                AxoButton.Root(i18n("icu:close"), variant: .strongPrimary, size: .md, action: closeWindow)
            }
            .padding(.top, 16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AxoColor.surfacePrimary)
        .onExitCommand(perform: closeWindow)
    }
}
