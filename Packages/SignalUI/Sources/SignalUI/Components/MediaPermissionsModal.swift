// Port of ts/components/MediaPermissionsModal.dom.tsx: the alert shown when the camera or
// microphone is denied — who asks (a call, a voice note), then numbered steps: open the
// system settings ("Go to settings"), and turn on Signal (on macOS with a picture of the
// switch: images/macos-switch.svg, a 30×20 inline-block, `vertical-align: middle` from
// Tailwind's preflight, which deepens that line's box).

import CoreText
import SignalI18n
import SwiftUI

public struct MediaPermissionsModal: View {
    public enum MediaType: String, Sendable { case camera, microphone }
    public enum Requestor: Sendable { case call, voiceNote }
    public enum OSName: Sendable { case macos, windows }

    let mediaType: MediaType
    let requestor: Requestor
    let osName: OSName
    let openSystemMediaPermissions: (MediaType) -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(mediaType: MediaType, requestor: Requestor, osName: OSName = .macos, openSystemMediaPermissions: @escaping (MediaType) -> Void = { _ in },
                onClose: @escaping () -> Void = {}) {
        self.mediaType = mediaType
        self.requestor = requestor
        self.osName = osName
        self.openSystemMediaPermissions = openSystemMediaPermissions
        self.onClose = onClose
    }

    var title: String { i18n(mediaType == .camera ? "icu:MediaPermissionsModal__title--camera" : "icu:MediaPermissionsModal__title--microphone") }

    var subtitle: String {
        switch requestor {
        case .call: i18n(mediaType == .camera ? "icu:MediaPermissionsModal__subtitle--call--camera" : "icu:MediaPermissionsModal__subtitle--call")
        case .voiceNote: i18n("icu:MediaPermissionsModal__subtitle--voice-note")
        }
    }

    var stepTwo: String {
        switch osName {
        case .macos: i18n("icu:MediaPermissionsModal__step-2")
        case .windows: i18n(mediaType == .camera ? "icu:MediaPermissionsModal__step-2--windows--camera" : "icu:MediaPermissionsModal__step-2--windows--microphone")
        }
    }

    static var style: CSSTextStyle { CSSTextStyle(AxoType.bodyMedium) }

    /// The `::marker` ("1. ", inside): Chromium's UA style gives it tabular figures.
    static var markerStyle: CSSTextStyle { style.tabularNums() }

    static func markerWidth(_ n: Int) -> CGFloat {
        CSSTextLayout.make(runs: [CSSTextRun("\(n). "), .inlineBlock("", CSSInlineBlock(paddingInline: 0.5))], markerStyle, wrap: .nowrap,
                           maxWidth: nil, colors: nil).width - 1
    }

    /// `<ol class="list-inside list-decimal">` item: the marker inline before the text.
    func item(_ n: Int, _ text: String) -> some View {
        ZStack(alignment: .topLeading) {
            CSSText("\(n).", style: Self.markerStyle, wrap: .nowrap, color: .labelPrimary)
            CSSText(text, style: Self.style, color: .labelPrimary).padding(.leading, Self.markerWidth(n))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The second step on macOS: marker, the switch (me-1), the text, on a line whose box the
    /// middle-aligned 20px image extends below the strut.
    var macStepTwo: some View {
        let style = Self.style
        let font = style.ctFont
        let a = CTFontGetAscent(font).rounded(), d = CTFontGetDescent(font).rounded()
        let halfLeading = ((style.lineHeight - (a + d)) / 2).rounded(.down)
        let strutAbove = halfLeading + a, strutBelow = style.lineHeight - strutAbove
        let imageCentre = CTFontGetXHeight(font) / 2            // above the baseline
        let above = max(strutAbove, imageCentre + 10), below = max(strutBelow, 10 - imageCentre)
        let marker = Self.markerWidth(2)
        return ZStack(alignment: .topLeading) {
            CSSText("2.", style: Self.markerStyle, wrap: .nowrap, color: .labelPrimary).padding(.top, above - strutAbove)
            CSSText(stepTwo, style: style, color: .labelPrimary).padding(.leading, marker + 30 + 4).padding(.top, above - strutAbove)
            SignalIcon("macos-switch")      // 30×20
                .offset(x: marker, y: above - imageCentre - 10)
        }
        .frame(height: above + below, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(title)
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(subtitle, style: Self.style, color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        item(1, i18n("icu:MediaPermissionsModal__step-1", ["buttonName": .string(i18n("icu:MediaPermissionsModal__open"))]))
                        if osName == .macos { macStepTwo } else { item(2, stepTwo) }
                    }
                }
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Action(i18n("icu:MediaPermissionsModal__open"), variant: .strongPrimary) { openSystemMediaPermissions(mediaType) }
            }
        }
    }
}
