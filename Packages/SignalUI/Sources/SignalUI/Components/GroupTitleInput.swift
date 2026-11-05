// Ports of ts/components/GroupTitleInput.dom.tsx and GroupDescriptionInput.dom.tsx: the legacy
// Input for a group's name (32 characters) and description (expandable, 480 characters /
// 8 KiB, the remaining count from 380).

import SignalI18n
import SwiftUI

public struct GroupTitleInput: View {
    @Binding var value: String
    let disabled: Bool
    let autoFocus: Bool
    @Environment(\.i18n) var i18n
    public init(value: Binding<String>, disabled: Bool = false, autoFocus: Bool = false) {
        _value = value
        self.disabled = disabled
        self.autoFocus = autoFocus
    }
    public var body: some View {
        Input(value: $value, placeholder: i18n("icu:setGroupMetadata__group-name-placeholder"), clearLabel: i18n("icu:cancel"),
              disabled: disabled, maxLengthCount: 32, autoFocus: autoFocus)
    }
}

public struct GroupDescriptionInput: View {
    @Binding var value: String
    let disabled: Bool
    let autoFocus: Bool
    @Environment(\.i18n) var i18n
    public init(value: Binding<String>, disabled: Bool = false, autoFocus: Bool = false) {
        _value = value
        self.disabled = disabled
        self.autoFocus = autoFocus
    }
    public var body: some View {
        Input(value: $value, placeholder: i18n("icu:setGroupMetadata__group-description-placeholder"), clearLabel: i18n("icu:cancel"),
              disabled: disabled, expandable: true, maxByteCount: 8192, maxLengthCount: 480, whenToShowRemainingCount: 380,
              autoFocus: autoFocus)
    }
}
