// Port of ts/components/CallingHeader.dom.tsx: the call's top-right buttons (absolute,
// end 24px, top 32px + the title-bar drag area): layout menu (group calls of 3+), settings,
// picture-in-picture, cancel — elevated-secondary lg icon buttons, 12px apart.

import SignalI18n
import SwiftUI

/// `CallViewMode` (ts/types/Calling.std.ts)
public enum CallViewMode: String, Sendable, CaseIterable {
    case paginated = "Paginated", sidebar = "Sidebar", speaker = "Speaker", presentation = "Presentation"

    /// `getCallViewModeIcon`
    public var symbol: AxoSymbol.Name {
        switch self {
        case .paginated: "grid"
        case .sidebar: "grid-sidebar"
        case .speaker, .presentation: "sidebar"
        }
    }
}

public struct CallingHeader: View {
    let callViewMode: CallViewMode?
    let isGroupCall: Bool
    let participantCount: Int
    let onCancel: (() -> Void)?
    let togglePip: (() -> Void)?
    let toggleSettings: (Bool) -> Void
    let changeCallView: ((CallViewMode) -> Void)?
    @State var layoutMenuOpen = false
    @Environment(\.i18n) var i18n

    public init(callViewMode: CallViewMode? = nil, isGroupCall: Bool = false, participantCount: Int, onCancel: (() -> Void)? = nil,
                togglePip: (() -> Void)? = nil, toggleSettings: @escaping (Bool) -> Void, changeCallView: ((CallViewMode) -> Void)? = nil) {
        self.callViewMode = callViewMode
        self.isGroupCall = isGroupCall
        self.participantCount = participantCount
        self.onCancel = onCancel
        self.togglePip = togglePip
        self.toggleSettings = toggleSettings
        self.changeCallView = changeCallView
    }

    /// The selected layout (Presentation shows Speaker as selected).
    var layoutValue: Binding<String?> {
        Binding(get: { (callViewMode == .presentation ? .speaker : callViewMode)?.rawValue },
                set: { v in if let v, let m = CallViewMode(rawValue: v) { changeCallView?(m) } })
    }

    public var body: some View {
        HStack(spacing: 12) {
            if isGroupCall, participantCount > 2, let mode = callViewMode, changeCallView != nil {
                AxoDropdownMenu.Root(isOpen: $layoutMenuOpen, align: .end) {
                    AxoIconButton.Root(label: i18n("icu:calling__change-layout"), variant: .elevatedSecondary, size: .lg, symbol: mode.symbol)
                } items: {
                    AxoDropdownMenu.RadioGroup(value: layoutValue) {
                        AxoDropdownMenu.RadioItem(i18n("icu:calling__layout--paginated"), value: CallViewMode.paginated.rawValue, symbol: "grid")
                        AxoDropdownMenu.RadioItem(i18n("icu:calling__layout--overflow"), value: CallViewMode.sidebar.rawValue, symbol: "grid-sidebar")
                        AxoDropdownMenu.RadioItem(i18n("icu:calling__layout--speaker"), value: CallViewMode.speaker.rawValue, symbol: "sidebar")
                    }
                }
            }
            AxoIconButton.Root(label: i18n("icu:callingDeviceSelection__settings-v2"), variant: .elevatedSecondary, size: .lg, symbol: "settings") {
                toggleSettings(true)
            }
            if let togglePip {
                AxoIconButton.Root(label: i18n("icu:calling__pip--on"), variant: .elevatedSecondary, size: .lg, symbol: "pip", action: togglePip)
            }
            if let onCancel {
                AxoIconButton.Root(label: i18n("icu:cancel"), variant: .elevatedSecondary, size: .lg, symbol: "x", action: onCancel)
            }
        }
    }
}
